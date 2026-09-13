//  ScoreboardModel.swift
//  Estado del marcador: descarga, caché, refresco automático y widgets.

import Foundation
import SwiftUI
import UIKit
import WidgetKit

@MainActor
final class ScoreboardModel: ObservableObject {
    /// Un marcador por liga: al deslizar entre ellas se enseña el suyo al
    /// instante, sin esperar a la descarga.
    @Published private(set) var snapshots: [String: MatchupSnapshot] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// Todas tus ligas y cuál se está mirando.
    @Published private(set) var book: LeagueBook
    /// True mientras corre el partido de mentira del menú de pruebas.
    @Published private(set) var isSimulating = false
    /// True durante la cuenta atrás de una anotación simulada.
    @Published private(set) var pendingSimulation = false
    /// Noticias de tus jugadores, las últimas primero.
    @Published private(set) var news: [NewsItem] = []
    /// Identificador de la última anotación tuya. Al cambiar, la pantalla
    /// lanza la celebración.
    @Published private(set) var celebrationID: String?

    private let service = MatchupService()
    private let live = LiveActivityController.shared
    private var refreshTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var statsWeek: Int?

    init() {
        book = SharedStore.loadBook()
        // Se arranca con lo último que se vio: la pantalla nunca aparece vacía.
        for liga in book.leagues {
            snapshots[liga.id] = SharedStore.cachedSnapshot(for: liga)
        }
    }

    /// La liga que se está mirando.
    var config: LeagueConfig { book.active ?? .default }

    /// El marcador de la liga activa.
    var snapshot: MatchupSnapshot? {
        get { snapshots[config.id] }
        set { snapshots[config.id] = newValue }
    }

    /// El marcador de una liga concreta, para las páginas que no están activas.
    func snapshot(for league: LeagueConfig) -> MatchupSnapshot? {
        snapshots[league.id]
    }

    var needsSetup: Bool { book.isEmpty }

    var hasMultipleLeagues: Bool { book.leagues.count > 1 }

    // MARK: - Descarga

    func refresh(showSpinner: Bool = true) async {
        guard config.isComplete else { return }
        // Con el partido simulado en marcha, traer los puntos reales borraría
        // lo que se está probando.
        guard !isSimulating else { return }
        if showSpinner { isLoading = true }
        defer { isLoading = false }

        do {
            let fresh = try await service.snapshot(for: config)
            await apply(fresh)
            lastError = nil
            Task { await syncWeekStats(week: fresh.week) }
            Task { await syncNews(for: fresh) }
        } catch {
            lastError = error.localizedDescription
            // Si no había nada en pantalla, al menos se enseña lo guardado.
            if snapshot == nil { snapshot = SharedStore.staleSnapshot(for: config) }
            else { snapshot?.isStale = true }
        }
    }

    /// Todo marcador nuevo entra por aquí, venga de la red o del simulador:
    /// se detectan las anotaciones, se guarda, se avisa a los widgets, a la
    /// Live Activity y al usuario.
    private func apply(_ fresh: MatchupSnapshot) async {
        let anterior = snapshot
        var actualizado = fresh

        // Lo que ha pasado desde la última lectura: quién ha anotado.
        let anotaciones = ScoringDetector.plays(previous: snapshot, current: fresh)
        actualizado.recentPlays = Array((anotaciones + (snapshot?.plays ?? [])).prefix(6))

        let cambioAlgo = anterior?.me.points != actualizado.me.points
            || anterior?.opponentPoints != actualizado.opponentPoints
            || !anotaciones.isEmpty

        snapshot = actualizado
        SharedStore.cache(actualizado, for: config)
        // iOS raciona las recargas de widget: pedirlas cada minuto sin que haya
        // cambiado nada agota el presupuesto y luego no recarga cuando importa.
        if cambioAlgo {
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Las fotos, en disco, para el widget y la Live Activity.
        Task { await HeadshotCache.prefetch(lineup: actualizado.lineup) }

        // Que te pasen (o volver a pasar tú) es el aviso que más se agradece.
        if let anterior, anterior.opponent != nil,
           anterior.isLeading != actualizado.isLeading {
            await Notifier.leadChange(
                tookLead: actualizado.isLeading,
                difference: actualizado.difference,
                opponent: actualizado.opponent?.name ?? "el rival"
            )
        }

        // Celebrar solo lo tuyo: que anote el rival no se festeja.
        if let mia = anotaciones.first(where: { $0.isMine }) {
            celebrationID = mia.id
        }

        // Si el partido ya se mueve y no hay actividad encendida, se enciende
        // sola. Solo funciona con la app abierta: iOS no permite arrancar una
        // Live Activity desde segundo plano sin push.
        if SharedStore.autoStartLiveActivity,
           !live.isRunning,
           actualizado.looksLive,
           actualizado.opponent != nil {
            live.start(with: actualizado)
        }

        live.update(with: actualizado, play: anotaciones.first)
        await live.notify(plays: anotaciones, in: actualizado)
    }

    /// Yardas y proyecciones de la jornada. Van en llamadas aparte del
    /// marcador, así que se piden por su cuenta y se guardan para el widget.
    private func syncWeekStats(week: Int) async {
        guard let season = try? await service.currentSeason(), !season.isEmpty else { return }
        async let estadisticas = WeekStatsStore.shared.refreshIfNeeded(season: season, week: week)
        async let proyecciones = ProjectionStore.shared.refreshIfNeeded(season: season, week: week)
        // Qué partidos han acabado: sin eso la proyección cuenta puntos que
        // ya no pueden llegar.
        async let partidos = GameStatusStore.shared.refreshIfNeeded()
        _ = await (estadisticas, proyecciones, partidos)
        // La primera vez de cada jornada el marcador se montó sin ellas:
        // se vuelve a montar, ya con yardas. Después el TTL de la caché manda.
        // Ojo: `refresh()` llama a este método, así que volver a refrescar sin
        // condición sería un bucle infinito. Solo se rehace la primera vez de
        // cada jornada, cuando el marcador se montó sin estadísticas; el resto
        // de las veces lo recoge el refresco automático del minuto siguiente.
        if statsWeek != week {
            statsWeek = week
            await refresh(showSpinner: false)
        }
    }

    /// Noticias de los jugadores del marcador. ESPN etiqueta cada artículo con
    /// los atletas que salen en él, así que el cruce es exacto.
    private func syncNews(for snapshot: MatchupSnapshot) async {
        let catalogo = await PlayerCatalog.shared.cached()
        guard !catalogo.isEmpty else { return }

        var jugadores = Set<String>()
        for fila in snapshot.lineup {
            if let mine = fila.mine { jugadores.insert(mine.playerID) }
        }
        for suplente in snapshot.bench ?? [] { jugadores.insert(suplente.playerID) }
        guard !jugadores.isEmpty else { return }

        let recibidas = await NewsFeed.shared.refresh(for: jugadores, catalog: catalogo)
        news = recibidas

        // Solo se avisa de lo que no se había avisado ya.
        for noticia in NewsSeen.filterNew(recibidas).prefix(2) {
            let nombre = noticia.playerIDs
                .compactMap { catalogo[$0]?.name }
                .first
            await Notifier.news(noticia, playerName: nombre)
        }
    }

    // MARK: - Pruebas

    /// Mete una anotación de mentira por el mismo camino que las de verdad.
    ///
    /// El retraso da tiempo a cerrar la app y ver llegar el aviso y la Live
    /// Activity, que es de lo que se trata. Se pide una prórroga al sistema
    /// para que el trabajo no se corte al salir de la app.
    func simulate(
        _ play: MatchSimulator.Play,
        mine: Bool? = nil,
        delay: TimeInterval = 2
    ) async {
        guard let actual = snapshot,
              let simulado = MatchSimulator.apply(play, to: actual, mine: mine)
        else { return }

        await live.requestNotificationPermission()

        if delay > 0 {
            pendingSimulation = true
            let prorroga = UIApplication.shared.beginBackgroundTask(withName: "anotación simulada")
            defer {
                pendingSimulation = false
                if prorroga != .invalid { UIApplication.shared.endBackgroundTask(prorroga) }
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await apply(simulado)
        } else {
            await apply(simulado)
        }
    }

    /// Un partido de mentira: alguien anota cada pocos segundos.
    func startFakeGame(every seconds: UInt64 = 12) {
        guard !isSimulating else { return }
        isSimulating = true
        stopAutoRefresh()
        simulationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                let jugada = MatchSimulator.Play.allCases.randomElement() ?? .touchdown
                await self.simulate(jugada, delay: 0)
            }
        }
    }

    func stopFakeGame() {
        simulationTask?.cancel()
        simulationTask = nil
        isSimulating = false
        startAutoRefresh()
    }

    /// Los nombres de la alineación vienen del catálogo; se pone al día en
    /// segundo plano y luego se vuelve a montar el marcador ya con nombres.
    func refreshCatalogIfNeeded() async {
        let stale = await PlayerCatalog.shared.isStale
        guard stale else { return }
        let catalogo = await PlayerCatalog.shared.refreshIfNeeded()
        await refresh(showSpinner: false)
        await checkInjuries(with: catalogo)
    }

    /// Avisa de los cambios en el parte de lesiones de los jugadores que ves.
    private func checkInjuries(with catalog: [String: CatalogPlayer]) async {
        guard let actual = snapshot else { return }
        let cambios = InjuryWatcher.changes(in: actual, catalog: catalog)
        for cambio in cambios.prefix(3) {
            await Notifier.injury(cambio)
        }
    }

    func forceCatalogRefresh() async {
        isLoading = true
        defer { isLoading = false }
        let catalogo = await PlayerCatalog.shared.refreshIfNeeded(force: true)
        await refresh(showSpinner: false)
        await checkInjuries(with: catalogo)
    }

    // MARK: - Live Activity

    func startLiveActivity() async {
        guard let snapshot else { return }
        await live.requestNotificationPermission()
        live.start(with: snapshot)
    }

    func stopLiveActivity() async {
        await live.stop()
    }

    // MARK: - Ajustes

    /// Añade una liga (o actualiza la que ya estaba) y la deja activa.
    func update(config newConfig: LeagueConfig) {
        book.upsert(newConfig)
        persist()
        showLeague(newConfig)
    }

    /// Cambia de liga sin descargar nada primero: se enseña al momento lo
    /// último que se vio de esa liga y luego se refresca.
    func activate(_ league: LeagueConfig) {
        guard league.id != book.activeID else { return }
        book.activeID = league.id
        persist()
        showLeague(league)
    }

    func remove(_ league: LeagueConfig) {
        book.remove(league)
        snapshots.removeValue(forKey: league.id)
        persist()
        if let siguiente = book.active {
            showLeague(siguiente)
        } else {
            snapshot = nil
        }
    }

    private func showLeague(_ league: LeagueConfig) {
        // Cada liga guarda su propio marcador, así que el cambio es inmediato.
        if snapshots[league.id] == nil {
            snapshots[league.id] = SharedStore.cachedSnapshot(for: league)
        }
        statsWeek = nil
        Task { await refresh(showSpinner: snapshots[league.id] == nil) }
    }

    /// Cambiar de liga desde el deslizador de páginas.
    func activate(id: String) {
        guard let liga = book.leagues.first(where: { $0.id == id }) else { return }
        activate(liga)
    }

    private func persist() {
        SharedStore.save(book)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Refresco automático

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(showSpinner: self.snapshot == nil)
            await self.refreshCatalogIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppConfig.foregroundRefreshSeconds * 1_000_000_000)
                if Task.isCancelled { return }
                await self.refresh(showSpinner: false)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
