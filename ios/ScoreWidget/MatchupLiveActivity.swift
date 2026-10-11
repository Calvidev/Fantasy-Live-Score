//  MatchupLiveActivity.swift
//  La Live Activity: marcador en la pantalla de bloqueo, en la Dynamic Island
//  y en el Apple Watch, con la última anotación —foto, nombre y puntos—
//  destacada.
//
//  Lo del reloj no necesita app de watchOS: desde iOS 18 el sistema lleva solo
//  las Live Activities del iPhone al Smart Stack del reloj. Lo que sí hace
//  falta es pedirlo (`supplementalActivityFamily`) y dar una vista para ese
//  tamaño; sin ella el sistema improvisa una a partir de la Dynamic Island, y
//  la de aquí —cuatro filas pensadas para 160 puntos de alto— sale apretada y
//  con letra ilegible en una pantalla de 45 mm.

import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

struct MatchupLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchupActivityAttributes.self) { context in
            LockScreenLiveView(
                attributes: context.attributes, state: context.state
            )
            .activityBackgroundTint(Color(hex: "111113"))
            .activitySystemActionForegroundColor(Theme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandTeam(
                        name: context.attributes.myTeam,
                        points: context.state.myPoints,
                        projection: context.state.myProjection,
                        mine: true
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandTeam(
                        name: context.attributes.opponentTeam,
                        points: context.state.opponentPoints,
                        projection: context.state.opponentProjection,
                        mine: false
                    )
                }
                // Nada en el centro: compite por el ancho con las columnas de
                // los equipos y las deja sin sitio. La jugada va abajo, que es
                // la única región que ocupa todo el ancho.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ScoreBar(share: context.state.share, height: 5)
                        if let play = context.state.lastPlay {
                            PlayBanner(play: play, compact: false)
                        } else {
                            HStack {
                                Text("Semana \(context.attributes.week)")
                                Spacer()
                                Text("Titulares \(context.state.myStarters):\(context.state.opponentStarters)")
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            } compactLeading: {
                Text(context.state.myPoints.fantasyPoints)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(value: context.state.myPoints))
            } compactTrailing: {
                Text(context.state.opponentPoints.fantasyPoints)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: context.state.opponentPoints))
            } minimal: {
                Text(context.state.difference.signedFantasyPoints)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(context.state.difference >= 0 ? Theme.accent : Color.red)
            }
            .keylineTint(Theme.accent)
        }
        // Sin esto, la actividad no sale en el Smart Stack del reloj.
        .supplementalActivityFamily([.small])
    }
}

// MARK: - Apple Watch

/// La misma actividad, en el Smart Stack del reloj.
///
/// Dos cosas mandan aquí y ninguna aplica en el teléfono:
///
/// **No hay fotos.** La vista de bloqueo lee los retratos y los escudos de
/// archivos que la app deja en el grupo de apps, y el reloj es otro aparato: no
/// comparte ese disco. Cualquier imagen saldría en blanco, así que esto es
/// todo texto a propósito.
///
/// **No hay sitio.** La tarjeta del Smart Stack da una fracción de lo que da la
/// pantalla de bloqueo y se mira de reojo, con la muñeca levantada un segundo.
/// Así que solo lo imprescindible: quién va ganando y por cuánto.
struct WatchLiveView: View {
    var attributes: MatchupActivityAttributes
    var state: MatchupActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(attributes.leagueName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let probabilidad = state.winChanceText {
                    Text(probabilidad)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(state.share >= 0.5 ? Theme.accent : Color.red)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(state.myPoints.fantasyPoints)
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(value: state.myPoints))
                Text("–")
                    .foregroundStyle(.white.opacity(0.35))
                Text(state.opponentPoints.fantasyPoints)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: state.opponentPoints))
            }
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .lineLimit(1)

            ScoreBar(share: state.share, height: 4)

            // La última jugada solo si cabe: es lo primero que sobra.
            if let play = state.lastPlay {
                Text("\(play.name) \(play.delta.signedFantasyPoints)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(play.isMine ? Theme.accent : .white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Pantalla de bloqueo

struct LockScreenLiveView: View {
    var attributes: MatchupActivityAttributes
    var state: MatchupActivityAttributes.ContentState

    /// `.small` es el reloj. El sistema pinta la misma vista en los dos
    /// sitios, así que hay que preguntar en cuál estamos.
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            WatchLiveView(attributes: attributes, state: state)
        default:
            telefono
        }
    }

    // La pantalla de bloqueo da unos 160 puntos de alto y recorta lo que
    // sobre, así que aquí se cuenta cada punto: cuatro filas y ninguna más.
    private var telefono: some View {
        VStack(spacing: 7) {
            cabecera
            marcador
            ScoreBar(share: state.share, height: 5)
            if let play = state.lastPlay {
                PlayBanner(play: play, compact: false)
                    .id(play.id)
                    .transition(.push(from: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var cabecera: some View {
        HStack(spacing: 5) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
            Text(attributes.leagueName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("Sem. \(attributes.week)")
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.45))
        .lineLimit(1)
    }

    /// Cada equipo con su foto, sus puntos y —más pequeña— su proyección,
    /// como en Sleeper. En el centro, la diferencia y la probabilidad.
    private var marcador: some View {
        HStack(alignment: .center, spacing: 8) {
            TeamLine(
                avatarURL: attributes.myAvatarURL,
                name: attributes.myTeam,
                points: state.myPoints,
                projection: state.myProjection,
                alignment: .leading
            )

            VStack(spacing: 2) {
                Text(state.difference.signedFantasyPoints)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.difference >= 0 ? Theme.accent : Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
                if let winChance = state.winChanceText {
                    Text(winChance)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle((state.isFavorite ?? true) ? Theme.accent : Color.red)
                }
            }
            .fixedSize()

            TeamLine(
                avatarURL: attributes.opponentAvatarURL,
                name: attributes.opponentTeam,
                points: state.opponentPoints,
                projection: state.opponentProjection,
                alignment: .trailing
            )
        }
    }
}

/// Foto, puntos y proyección de un equipo, en una fila.
struct TeamLine: View {
    var avatarURL: String?
    var name: String
    var points: Double
    var projection: Double?
    var alignment: HorizontalAlignment

    private var esIzquierda: Bool { alignment == .leading }

    var body: some View {
        HStack(spacing: 6) {
            if esIzquierda { avatar }
            VStack(alignment: alignment, spacing: 0) {
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if !esIzquierda, let projection {
                        proyeccion(projection)
                    }
                    Text(points.fantasyPoints)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        // Lo único que el sistema deja animar aquí: que los
                        // dígitos rueden cuando llega una actualización.
                        .contentTransition(.numericText(value: points))
                    if esIzquierda, let projection {
                        proyeccion(projection)
                    }
                }
            }
            if !esIzquierda { avatar }
        }
        .frame(maxWidth: .infinity, alignment: esIzquierda ? .leading : .trailing)
    }

    /// La foto sale del archivo que la app dejó en el grupo de apps: aquí no
    /// hay red que valga.
    private var avatar: some View {
        Group {
            if let datos = AvatarLoader.cachedData(for: avatarURL.flatMap(URL.init(string:))),
               let imagen = UIImage(data: datos) {
                Image(uiImage: imagen).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
    }

    private func proyeccion(_ valor: Double) -> some View {
        Text(valor.fantasyPoints)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.4))
    }
}

// MARK: - La anotación

/// Foto, nombre y puntos de quien acaba de anotar. La foto sale del archivo
/// que la app dejó en el grupo de apps: aquí no hay red.
struct PlayBanner: View {
    var play: ScoringPlay
    var compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            headshot
            VStack(alignment: .leading, spacing: 0) {
                Text(play.name)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // Lo que lleva hecho: "6 rec · 88 yds · 1 TD".
                Text(play.stats ?? play.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // Quién es se sabe por el color de los puntos: en verde los
                // tuyos, en rojo los del rival. Una línea menos.
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text("+\(play.delta.fantasyPoints)")
                    .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(play.isMine ? Theme.accent : Color.red)
                Text("\(play.total.fantasyPoints) pts")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 5)
        .background(
            compact ? Color.clear : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var headshot: some View {
        Group {
            if let data = HeadshotCache.cachedData(playerID: play.playerID),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
        .background(Color.white.opacity(0.08), in: Circle())
        .clipShape(Circle())
    }
}

struct IslandTeam: View {
    var name: String
    var points: Double
    var projection: Double?
    var mine: Bool

    var body: some View {
        VStack(alignment: mine ? .leading : .trailing, spacing: 1) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(points.fantasyPoints)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(mine ? Theme.accent : .white)
                if let projection {
                    Text(projection.fantasyPoints)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
}
