//  ScoreboardView.swift
//  El marcador del widget, en grande y con la alineación debajo.

import SwiftUI
import UIKit

/// Con varias ligas, cada una es una página: se pasa deslizando y los puntitos
/// de abajo dicen cuántas hay. Con una sola liga no hay deslizador ni puntos.
struct ScoreboardView: View {
    @EnvironmentObject private var model: ScoreboardModel

    var body: some View {
        if model.book.leagues.count > 1 {
            VStack(spacing: 0) {
                LeagueDots(
                    count: model.book.leagues.count,
                    index: model.book.leagues.firstIndex { $0.id == model.book.activeID } ?? 0
                )
                TabView(selection: seleccion) {
                    ForEach(model.book.leagues) { liga in
                        LeaguePage(league: liga)
                            .tag(liga.id)
                    }
                }
                // Los puntos propios van arriba: los del sistema flotan sobre
                // el contenido y tapaban la última fila de la alineación.
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        } else {
            LeaguePage(league: model.config)
        }
    }

    /// Deslizar cambia la liga activa, igual que elegirla en el menú.
    private var seleccion: Binding<String> {
        Binding(
            get: { model.book.activeID ?? model.config.id },
            set: { model.activate(id: $0) }
        )
    }
}

/// Los puntos que dicen cuántas ligas hay y en cuál estás.
struct LeagueDots: View {
    var count: Int
    var index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { posicion in
                Capsule()
                    .fill(posicion == index ? Theme.accent : Color.white.opacity(0.22))
                    .frame(width: posicion == index ? 16 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: index)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }
}

/// El marcador de UNA liga. Cada página tiene el suyo, así que al deslizar se
/// ve al instante lo último que se supo de esa liga.
struct LeaguePage: View {
    var league: LeagueConfig

    @EnvironmentObject private var model: ScoreboardModel

    private var snapshot: MatchupSnapshot? { model.snapshot(for: league) }
    private var esLaActiva: Bool { league.id == model.book.activeID }
    /// Otra jornada, pasada o futura: lo que se ve no es lo que está pasando
    /// ahora, así que todo lo que hable del presente se calla.
    private var otraJornada: Bool { model.isViewingOtherWeek(league) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let snapshot {
                    ScoreCard(snapshot: snapshot, league: league)
                    HStack(spacing: 8) {
                        NavigationLink {
                            StandingsView(league: league)
                        } label: {
                            ActionTile(title: "Clasificación", icon: "list.number")
                        }
                        NavigationLink {
                            FreeAgentsView(league: league)
                        } label: {
                            ActionTile(title: "Libres", icon: "person.badge.plus")
                        }
                        NavigationLink {
                            SeasonView(league: league, week: snapshot.week)
                        } label: {
                            ActionTile(title: "Temporada", icon: "chart.bar.fill")
                        }
                        ShareScoreButton(snapshot: snapshot)
                    }
                    if otraJornada {
                        OtherWeekNote(week: snapshot.week, isFuture: snapshot.isFutureWeek) {
                            Task { await model.pickWeek(nil, for: league) }
                        }
                    } else {
                        LiveActivityButton(league: league)
                    }
                    if !snapshot.plays.isEmpty {
                        RecentPlaysSection(plays: snapshot.plays)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if esLaActiva, !otraJornada, !model.news.isEmpty {
                        NewsCard(items: model.news)
                    }
                    if !snapshot.lineup.isEmpty {
                        LineupSection(rows: snapshot.lineup)
                    } else if otraJornada {
                        Hint(text: "Sleeper no da alineación para esa jornada.")
                    } else {
                        Hint(text: "Cuando arranque la jornada aparecerá aquí la alineación titular con los puntos de cada jugador.")
                    }
                    // El banquillo va al final: es un lamento, no una noticia.
                    // Primero lo que está pasando, luego quién juega, y solo
                    // después lo que se dejó fuera.
                    if let informe = snapshot.benchReport, !informe.perfect {
                        BenchCard(report: informe)
                    }
                } else if model.isLoading {
                    ProgressView()
                        .padding(.top, 60)
                } else {
                    Hint(text: model.lastError ?? "Todavía no hay datos de esta jornada.")
                }

                if esLaActiva, let error = model.lastError, snapshot != nil {
                    ErrorNote(text: error)
                }

            }
            .padding(16)
            .animation(.snappy, value: snapshot?.plays.first?.id)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            model.activate(league)
            // Tirando hacia abajo se recarga lo que se está viendo, no otra
            // cosa: si estás en una jornada pasada, esa.
            if let vista = snapshot, otraJornada {
                await model.pickWeek(vista.week, for: league)
            } else {
                await model.refresh(showSpinner: false)
            }
        }
    }
}

/// La barra que sustituye al botón de seguir cuando se mira otra jornada:
/// dice dónde estás y devuelve a hoy de un toque.
struct OtherWeekNote: View {
    var week: Int
    var isFuture: Bool
    var onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: isFuture ? "calendar" : "clock.arrow.circlepath")
                Text(
                    isFuture
                        ? String(localized: "Vista previa de la semana \(week)")
                        : String(localized: "Viendo la semana \(week)")
                )
                Spacer(minLength: 4)
                Text("Volver a hoy")
                    .foregroundStyle(Theme.accent)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cabecera con selector de jornada

/// Como la cabecera del widget, pero con el selector de semana: en el widget
/// no se puede tocar nada, así que allí sigue siendo texto y ya está.
struct ScoreCardHeader: View {
    var snapshot: MatchupSnapshot
    var league: LeagueConfig

    @EnvironmentObject private var model: ScoreboardModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text(snapshot.leagueName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            WeekPicker(
                week: snapshot.week,
                liveWeek: model.liveWeek(for: league) ?? snapshot.week,
                isOtherWeek: model.isViewingOtherWeek(league)
            ) { elegida in
                Task { await model.pickWeek(elegida, for: league) }
            }
        }
    }
}

/// "Semana 1 ⌄". Al desplegarlo sale la temporada entera.
///
/// También hacia delante: Sleeper tiene el calendario hecho desde el draft, así
/// que se puede ver contra quién juegas la semana 7 y cómo pinta la cosa. Sin
/// las futuras, en la semana 1 el menú tenía una sola línea y no servía de nada.
struct WeekPicker: View {
    var week: Int
    var liveWeek: Int
    /// No se está mirando la jornada de hoy (da igual si antes o después).
    var isOtherWeek: Bool
    var onPick: (Int) -> Void

    private var jugadas: [Int] { Array((1...max(1, liveWeek)).reversed()) }
    private var porJugar: [Int] {
        guard liveWeek < MatchupSnapshot.lastWeek else { return [] }
        return Array((liveWeek + 1)...MatchupSnapshot.lastWeek)
    }

    var body: some View {
        Menu {
            // Lo jugado primero y de la más reciente hacia atrás: es donde
            // está lo que se mira casi siempre.
            Section("Jugadas") {
                ForEach(jugadas, id: \.self) { semana in
                    boton(semana)
                }
            }
            if !porJugar.isEmpty {
                Section("Por jugar") {
                    ForEach(porJugar, id: \.self) { semana in
                        boton(semana)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Semana \(week)")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11))
            // En verde cuando NO estás en la jornada de hoy: es la única
            // pista de que lo que se ve no es lo que está pasando ahora.
            .foregroundStyle(isOtherWeek ? Theme.accent : Color.white.opacity(0.6))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.pill, in: Capsule())
        }
        .accessibilityLabel("Jornada \(week). Tocar para cambiar de semana.")
    }

    @ViewBuilder
    private func boton(_ semana: Int) -> some View {
        Button {
            onPick(semana)
        } label: {
            if semana == week {
                Label(titulo(semana), systemImage: "checkmark")
            } else {
                Text(titulo(semana))
            }
        }
    }

    private func titulo(_ semana: Int) -> String {
        semana == liveWeek
            ? String(localized: "Semana \(semana) · en curso")
            : String(localized: "Semana \(semana)")
    }
}

// MARK: - Tarjeta del marcador

struct ScoreCard: View {
    var snapshot: MatchupSnapshot
    var league: LeagueConfig

    var body: some View {
        VStack(spacing: 14) {
            ScoreCardHeader(snapshot: snapshot, league: league)

            HStack(alignment: .top, spacing: 10) {
                TeamColumn(
                    team: snapshot.me, alignment: .leading,
                    avatarSize: 34, scoreSize: 40
                )
                VStack(spacing: 6) {
                    Text("vs")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    DifferencePill(difference: snapshot.difference)
                }
                .padding(.top, 8)
                TeamColumn(
                    team: snapshot.opponent, alignment: .trailing,
                    avatarSize: 34, scoreSize: 40,
                    placeholder: "Jornada de descanso"
                )
            }

            ScoreBar(share: snapshot.barShare, height: 10)

            if let projection = snapshot.projection {
                HStack(spacing: 10) {
                    WinChanceBadge(projection: projection)
                    ProjectionLine(
                        projection: projection, size: 12, note: snapshot.scoringLabel
                    )
                }
            }

            HStack {
                // Con proyección arriba ya se dice cuántos faltan; repetir los
                // titulares aquí era decir dos veces lo mismo.
                if snapshot.projection == nil {
                    Label(
                        "Titulares \(snapshot.me.startersCount):\(snapshot.opponent?.startersCount ?? 0)",
                        systemImage: "person.3.fill"
                    )
                }
                Spacer()
                if snapshot.isStale {
                    Label("Datos guardados", systemImage: "wifi.slash")
                } else {
                    Text("Actualizado \(snapshot.updatedAt.hourAndMinute)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(snapshot.me.name) \(snapshot.me.points.fantasyPoints) puntos, "
            + "\(snapshot.opponent?.name ?? "sin rival") \(snapshot.opponentPoints.fantasyPoints) puntos"
        )
    }
}

/// Los tres accesos bajo el marcador, todos con la misma pinta.
struct ActionTile: View {
    var title: String
    var icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Noticias

/// Noticias de tus jugadores. No de la NFL: de los tuyos.
struct NewsCard: View {
    var items: [NewsItem]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("De tus jugadores", systemImage: "newspaper.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            ForEach(items.prefix(4)) { noticia in
                Button {
                    if let url = noticia.url { openURL(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(noticia.headline)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let resumen = noticia.summary, !resumen.isEmpty {
                                Text(resumen)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(noticia.age)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if noticia.id != items.prefix(4).last?.id {
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Banquillo

/// "Dejaste 23,4 puntos en el banquillo": el dato que más duele y más se mira.
struct BenchCard: View {
    var report: BenchReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("En el banquillo", systemImage: "chair.lounge.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("−\(report.pointsLeft.fantasyPoints)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }

            Text("La mejor alineación posible sumaba \(report.best.fantasyPoints) en vez de \(report.actual.fantasyPoints).")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))

            ForEach(report.missed.prefix(3), id: \.playerID) { jugador in
                HStack(spacing: 10) {
                    PlayerHeadshot(line: jugador, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(jugador.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(jugador.stats ?? jugador.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(jugador.points.fantasyPoints)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Live Activity

/// Encender el seguimiento en la pantalla de bloqueo y la Dynamic Island.
struct LiveActivityButton: View {
    /// Cada página tiene su botón: se puede seguir más de una liga a la vez y
    /// el botón de una no debe encenderse porque se siga otra.
    var league: LeagueConfig

    @EnvironmentObject private var model: ScoreboardModel
    /// Se observa el controlador directamente: es quien sabe si la actividad
    /// está viva, y su estado cambia después de que el sistema la cierre.
    @ObservedObject private var live = LiveActivityController.shared

    private var siguiendo: Bool { live.isRunning(for: league.id) }

    var body: some View {
        if live.areActivitiesEnabled {
            Button {
                if siguiendo {
                    Task { await model.stopLiveActivity(for: league) }
                } else {
                    Task { await model.startLiveActivity(for: league) }
                }
            } label: {
                Label(
                    siguiendo
                        ? "Dejar de seguir el partido"
                        : "Seguir en la pantalla de bloqueo",
                    systemImage: siguiendo ? "stop.circle" : "bolt.badge.clock"
                )
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    siguiendo ? Theme.pill : Theme.accent.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .foregroundStyle(siguiendo ? Color.white.opacity(0.7) : Theme.accent)
                .animation(.easeInOut(duration: 0.2), value: siguiendo)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Últimas anotaciones

struct RecentPlaysSection: View {
    var plays: [ScoringPlay]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Últimas anotaciones")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            ForEach(plays.prefix(4)) { play in
                HStack(spacing: 10) {
                    PlayerHeadshot(
                        line: PlayerLine(
                            playerID: play.playerID,
                            points: play.total,
                            name: play.name,
                            position: play.position,
                            team: play.team
                        ),
                        size: 30
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(play.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(play.stats ?? (play.isMine ? "Tu equipo" : "Rival"))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("+\(play.delta.fantasyPoints)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(play.isMine ? Theme.accent : Color.red)
                }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Alineación

struct LineupSection: View {
    var rows: [LineupRow]
    @EnvironmentObject private var model: ScoreboardModel
    @State private var selected: PlayerLine?
    @State private var selectedSlot: String?

    private var myTotal: Double { rows.compactMap { $0.mine?.points }.reduce(0, +) }
    private var theirTotal: Double { rows.compactMap { $0.theirs?.points }.reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Alineación")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(myTotal.fantasyPoints) · \(theirTotal.fantasyPoints)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.bottom, 10)

            ForEach(rows) { row in
                LineupRowView(row: row) { jugador in
                    selected = jugador
                    selectedSlot = row.slotLabel
                }
                if row.id != rows.last?.id {
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sheet(item: $selected) { jugador in
            PlayerDetailView(line: jugador, news: model.news, slot: selectedSlot)
                .preferredColorScheme(.dark)
        }
    }
}

struct LineupRowView: View {
    var row: LineupRow
    var onTap: (PlayerLine) -> Void = { _ in }

    private var myPoints: Double { row.mine?.points ?? 0 }
    private var theirPoints: Double { row.theirs?.points ?? 0 }

    var body: some View {
        HStack(spacing: 8) {
            PlayerCell(line: row.mine, alignment: .leading, winning: myPoints > theirPoints)
                .contentShape(Rectangle())
                .onTapGesture { if let mine = row.mine { onTap(mine) } }

            Text(row.slotLabel)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 46)
                .padding(.vertical, 3)
                .background(Theme.pill, in: Capsule())

            PlayerCell(line: row.theirs, alignment: .trailing, winning: theirPoints > myPoints)
                .contentShape(Rectangle())
                .onTapGesture { if let theirs = row.theirs { onTap(theirs) } }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct PlayerCell: View {
    var line: PlayerLine?
    var alignment: HorizontalAlignment
    var winning: Bool

    var body: some View {
        HStack(spacing: 6) {
            if alignment == .trailing { points }
            if alignment == .trailing { headshot }
            VStack(alignment: alignment, spacing: 1) {
                HStack(spacing: 4) {
                    if alignment == .trailing, let lesion = line?.injuryLabel {
                        InjuryTag(label: lesion, severe: line?.injuryIsSevere ?? false)
                    }
                    Text(line?.displayName ?? "—")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(line == nil ? 0.3 : 1))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if alignment == .leading, let lesion = line?.injuryLabel {
                        InjuryTag(label: lesion, severe: line?.injuryIsSevere ?? false)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            if alignment == .leading { headshot }
            if alignment == .leading { points }
        }
    }

    /// La cara del jugador, pequeña. Sale del grupo de apps: la app la deja
    /// descargada al montar el marcador, así que aquí no hay red de por medio.
    private var headshot: some View {
        PlayerHeadshot(line: line, size: 24)
    }

    /// "6 rec · 88 yds" si hay estadísticas; si no, "WR CIN".
    private var subtitle: String {
        if let stats = line?.stats, !stats.isEmpty { return stats }
        return line?.subtitle ?? ""
    }

    private var points: some View {
        Text((line?.points ?? 0).fantasyPoints)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(winning ? Theme.accent : Color.white.opacity(0.8))
            .frame(width: 44, alignment: alignment == .trailing ? .leading : .trailing)
    }
}

// MARK: - Avisos

struct Hint: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ErrorNote: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// El parte médico, en corto y con color.
struct InjuryTag: View {
    var label: String
    var severe: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                (severe ? Color.red : Color.orange).opacity(0.2),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .foregroundStyle(severe ? Color.red : Color.orange)
            .fixedSize()
    }
}

/// Foto de un jugador, redonda y pequeña. Se sirve del archivo cacheado y, si
/// no está, la descarga ella misma: así cada fila se resuelve sola y no hace
/// falta coordinar nada desde fuera.
struct PlayerHeadshot: View {
    var line: PlayerLine?
    var size: CGFloat

    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.24)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .background(Theme.pill, in: Circle())
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: line?.playerID) { await load() }
    }

    private func load() async {
        guard let line else {
            data = nil
            return
        }
        if let cacheada = HeadshotCache.cachedData(playerID: line.playerID) {
            data = cacheada
            return
        }
        data = await HeadshotCache.prefetch(
            playerID: line.playerID, position: line.position, team: line.team
        )
    }
}
