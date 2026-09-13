//  LiveActivityController.swift
//  Enciende, actualiza y apaga las Live Activities —una por liga— y avisa
//  cuando alguien anota.
//
//  Límite que conviene tener presente: una Live Activity no se refresca sola
//  como un widget. Se actualiza cuando la app puede hacerlo (abierta, o en los
//  ratos de segundo plano que conceda iOS) o por push, y el push necesita la
//  capacidad de notificaciones, que pide cuenta de desarrollador de pago.

import ActivityKit
import Foundation
import UIKit
import UserNotifications

@MainActor
final class LiveActivityController: ObservableObject {
    /// Uno por proceso, pero **una actividad por liga**: iOS admite varias a la
    /// vez del mismo tipo. En la pantalla de bloqueo se apilan una debajo de
    /// otra; en la Dynamic Island se ve una cada vez y el sistema las va
    /// rotando. Quien sigue dos equipos un domingo quiere ver los dos.
    static let shared = LiveActivityController()

    /// Las ligas que se están siguiendo ahora mismo. Es `@Published` para que
    /// el botón de cada página sepa si le toca decir "seguir" o "dejar de
    /// seguir" sin preguntar por la actividad de otra liga.
    @Published private(set) var runningLeagueIDs: Set<String> = []
    @Published private(set) var lastError: String?

    private var activities: [String: Activity<MatchupActivityAttributes>] = [:]
    /// Sin esto, una notificación disparada con la app en primer plano no se
    /// ve ni suena — que es justo lo que pasa al probar el simulador.
    private let presenter = ForegroundNotificationPresenter()

    init() {
        // Al arrancar puede haber actividades vivas de una sesión anterior.
        for viva in Activity<MatchupActivityAttributes>.activities {
            // Las encendidas por una versión anterior no traen liga; se
            // adoptan bajo su nombre para poder apagarlas desde el botón.
            let clave = viva.attributes.leagueID ?? viva.attributes.leagueName
            activities[clave] = viva
        }
        runningLeagueIDs = Set(activities.keys)
        UNUserNotificationCenter.current().delegate = presenter
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Si se está siguiendo esta liga en concreto.
    func isRunning(for leagueID: String) -> Bool {
        runningLeagueIDs.contains(leagueID)
    }

    /// Si se está siguiendo alguna.
    var isRunning: Bool { !runningLeagueIDs.isEmpty }

    // MARK: - Ciclo de vida

    func start(for leagueID: String, with snapshot: MatchupSnapshot) {
        guard areActivitiesEnabled else {
            lastError = "Las Live Activities están desactivadas para esta app en Ajustes."
            return
        }
        guard activities[leagueID] == nil else {
            update(for: leagueID, with: snapshot)
            return
        }
        do {
            activities[leagueID] = try Activity.request(
                attributes: snapshot.activityAttributes(leagueID: leagueID),
                content: ActivityContent(state: snapshot.activityState(), staleDate: nil),
                pushType: nil  // sin push: se actualiza desde la app
            )
            runningLeagueIDs.insert(leagueID)
            lastError = nil
        } catch {
            // iOS no publica cuántas admite a la vez: depende del sistema y del
            // momento. Cuando dice que no, se dice con palabras en vez de
            // enseñar el error de ActivityKit, que no significa nada para nadie.
            lastError = runningLeagueIDs.isEmpty
                ? error.localizedDescription
                : "iOS no deja seguir más partidos a la vez. Deja de seguir alguno y vuelve a intentarlo."
        }
    }

    func update(for leagueID: String, with snapshot: MatchupSnapshot, play: ScoringPlay? = nil) {
        guard let activity = activities[leagueID] else { return }

        // Los nombres de los equipos y la liga son fijos en una Live Activity.
        // Si han cambiado (otra jornada, un cambio de nombre), hay que rehacerla
        // o enseñaría el marcador de una con el título de otra.
        if activity.attributes.leagueName != snapshot.leagueName
            || activity.attributes.myTeam != snapshot.me.name {
            Task {
                await restart(for: leagueID, with: snapshot)
            }
            return
        }

        Task {
            // Que la foto esté en disco antes de enseñarla: la Live Activity no
            // puede salir a la red mientras se pinta.
            if let play {
                await HeadshotCache.prefetch(
                    playerID: play.playerID, position: play.position, team: play.team
                )
            }
            let estado = snapshot.activityState(lastPlay: play)
            await activity.update(ActivityContent(state: estado, staleDate: nil))
        }
    }

    func stop(for leagueID: String) async {
        guard let viva = activities[leagueID] else { return }
        // Primero el estado, luego el trabajo: si no, el botón se queda con la
        // cara de "encendido" hasta que el sistema termine de cerrarla.
        activities[leagueID] = nil
        runningLeagueIDs.remove(leagueID)
        await viva.end(nil, dismissalPolicy: .immediate)
    }

    func stopAll() async {
        // Las claves aparte: `stop(for:)` modifica el diccionario, y recorrer
        // una vista de sus claves mientras se borra de él no es seguro.
        for clave in Array(activities.keys) {
            await stop(for: clave)
        }
    }

    private func restart(for leagueID: String, with snapshot: MatchupSnapshot) async {
        await stop(for: leagueID)
        start(for: leagueID, with: snapshot)
    }

    // MARK: - Avisos

    func requestNotificationPermission() async {
        await Notifier.requestPermission()
    }

    func notify(
        plays: [ScoringPlay], in snapshot: MatchupSnapshot, league: LeagueConfig? = nil
    ) async {
        await Notifier.plays(plays, in: snapshot, league: league)
    }
}

/// Deja que las notificaciones se vean aunque la app esté abierta.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
