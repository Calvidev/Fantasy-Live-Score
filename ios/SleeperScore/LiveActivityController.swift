//  LiveActivityController.swift
//  Enciende, actualiza y apaga la Live Activity, y avisa cuando alguien anota.
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
    /// Una sola por proceso: el sistema solo admite una actividad de este tipo
    /// y tanto el marcador como la pantalla la manejan.
    static let shared = LiveActivityController()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var activity: Activity<MatchupActivityAttributes>?
    /// Sin esto, una notificación disparada con la app en primer plano no se
    /// ve ni suena — que es justo lo que pasa al probar el simulador.
    private let presenter = ForegroundNotificationPresenter()

    init() {
        // Al arrancar puede haber una actividad viva de una sesión anterior.
        activity = Activity<MatchupActivityAttributes>.activities.first
        isRunning = activity != nil
        UNUserNotificationCenter.current().delegate = presenter
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Ciclo de vida

    func start(with snapshot: MatchupSnapshot) {
        guard areActivitiesEnabled else {
            lastError = "Las Live Activities están desactivadas para esta app en Ajustes."
            return
        }
        guard activity == nil else {
            update(with: snapshot)
            return
        }
        do {
            activity = try Activity.request(
                attributes: snapshot.activityAttributes,
                content: ActivityContent(state: snapshot.activityState(), staleDate: nil),
                pushType: nil  // sin push: se actualiza desde la app
            )
            isRunning = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func update(with snapshot: MatchupSnapshot, play: ScoringPlay? = nil) {
        guard let activity else { return }

        // Los nombres de los equipos y la liga son fijos en una Live Activity.
        // Si el usuario ha cambiado de liga, hay que rehacerla o enseñaría el
        // marcador de una con el título de otra.
        if activity.attributes.leagueName != snapshot.leagueName
            || activity.attributes.myTeam != snapshot.me.name {
            Task {
                await restart(with: snapshot)
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

    func stop() async {
        guard let viva = activity else { return }
        // Primero el estado, luego el trabajo: si no, el botón se queda con la
        // cara de "encendido" hasta que el sistema termine de cerrarla.
        activity = nil
        isRunning = false
        await viva.end(nil, dismissalPolicy: .immediate)
    }

    private func restart(with snapshot: MatchupSnapshot) async {
        await stop()
        start(with: snapshot)
    }

    // MARK: - Avisos

    func requestNotificationPermission() async {
        await Notifier.requestPermission()
    }

    func notify(plays: [ScoringPlay], in snapshot: MatchupSnapshot) async {
        await Notifier.plays(plays, in: snapshot)
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
