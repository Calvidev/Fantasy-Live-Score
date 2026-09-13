//  BackgroundRefresh.swift
//  Comprobar el marcador con la app cerrada.
//
//  Es lo más parecido a un aviso en vivo que se puede tener sin push (y el
//  push de verdad necesita servidor y cuenta de desarrollador de pago). iOS
//  decide cuándo conceder estos ratos: típicamente cada 15-30 minutos, y
//  aprende de cuánto usas la app. No es inmediato, pero es gratis y funciona
//  con el teléfono en el bolsillo.

import BackgroundTasks
import Foundation
import WidgetKit

enum BackgroundRefresh {
    static let taskID = "dev.calvi.sleeperscore.refresh"

    /// Se llama una vez al arrancar la app.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskID, using: nil
        ) { task in
            guard let refresco = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresco)
        }
    }

    /// Pide el siguiente rato. Hay que volver a pedirlo cada vez que se usa.
    static func schedule(after minutes: Double = 15) {
        let peticion = BGAppRefreshTaskRequest(identifier: taskID)
        peticion.earliestBeginDate = Date().addingTimeInterval(minutes * 60)
        try? BGTaskScheduler.shared.submit(peticion)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()  // encadenar el siguiente antes de nada

        let trabajo = Task {
            await run()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            trabajo.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Descarga el marcador, avisa de lo que haya pasado y deja todo guardado.
    /// Sin interfaz de por medio: esto corre con la app cerrada.
    static func run() async {
        let libro = SharedStore.loadBook()
        guard !libro.isEmpty else { return }

        // Todas las ligas, no solo la que estés mirando: si sigues dos equipos,
        // quieres enterarte de los dos.
        var frescos: [(LeagueConfig, MatchupSnapshot)] = []
        for liga in libro.leagues where liga.isComplete {
            guard let fresco = await refreshLeague(liga) else { continue }
            frescos.append((liga, fresco))
        }
        guard !frescos.isEmpty else { return }
        WidgetCenter.shared.reloadAllTimelines()

        // El parte de lesiones cambia mucho más despacio que el marcador, así
        // que solo se mira cuando el catálogo ya toca renovarse.
        //
        // Y se mira en todas las ligas. Antes se miraba solo en la última que
        // se hubiera descargado, así que con dos ligas te enterabas de las
        // lesiones de una y de la otra nunca — dependiendo del orden del
        // archivo, además, que no es algo que el usuario pueda ver.
        guard await PlayerCatalog.shared.isStale else { return }
        let catalogo = await PlayerCatalog.shared.refreshIfNeeded()
        for (liga, fresco) in frescos {
            for cambio in InjuryWatcher.changes(in: fresco, catalog: catalogo).prefix(3) {
                await Notifier.injury(cambio, league: liga)
            }
        }
    }

    /// Una liga: descarga, compara, avisa y guarda.
    private static func refreshLeague(_ league: LeagueConfig) async -> MatchupSnapshot? {
        let anterior = SharedStore.cachedSnapshot(for: league)
        guard var fresco = try? await MatchupService().snapshot(for: league) else { return nil }

        let anotaciones = ScoringDetector.plays(previous: anterior, current: fresco)
        fresco.recentPlays = Array((anotaciones + (anterior?.plays ?? [])).prefix(6))
        SharedStore.cache(fresco, for: league)

        await Notifier.plays(anotaciones, in: fresco, league: league)
        if let anterior, anterior.opponent != nil, anterior.isLeading != fresco.isLeading {
            await Notifier.leadChange(
                tookLead: fresco.isLeading,
                difference: fresco.difference,
                opponent: fresco.opponent?.name ?? "el rival",
                league: league
            )
        }
        return fresco
    }
}
