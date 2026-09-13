//  MatchupActivity.swift
//  El contrato de la Live Activity: lo que la app manda y el sistema pinta.
//
//  El estado de una Live Activity viaja serializado y tiene un límite duro de
//  4 KB, así que aquí no van imágenes: va el id del jugador y la foto se lee
//  del grupo de apps (`HeadshotCache`), que la app deja descargada antes.

import ActivityKit
import Foundation

/// Una anotación: alguien acaba de sumar puntos.
struct ScoringPlay: Codable, Hashable, Identifiable {
    var playerID: String
    var name: String
    var position: String?
    var team: String?
    /// Puntos totales del jugador tras la jugada.
    var total: Double
    /// Lo que acaba de sumar. Es el número que importa.
    var delta: Double
    /// True si es de tu equipo (para pintarlo en verde y no en rojo).
    var isMine: Bool
    /// Qué lleva hecho en la jornada: "6 rec · 88 yds · 1 TD".
    var stats: String?
    var at: Date

    var id: String { "\(playerID)-\(at.timeIntervalSince1970)" }

    var subtitle: String {
        [position, team].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct MatchupActivityAttributes: ActivityAttributes {
    /// Lo que cambia jugada a jugada.
    struct ContentState: Codable, Hashable {
        var myPoints: Double
        var opponentPoints: Double
        var myStarters: Int
        var opponentStarters: Int
        var lastPlay: ScoringPlay?
        var updatedAt: Date
        /// "62 %". Texto ya hecho: el estado viaja serializado y tiene un
        /// límite de 4 KB, así que aquí no van estructuras enteras.
        var winChanceText: String?
        /// La probabilidad en número, que es lo que pinta la barra.
        var winShare: Double?
        /// Proyección de cada lado, para enseñarla junto a sus puntos.
        var myProjection: Double?
        var opponentProjection: Double?
        /// Opcional para que un estado escrito por una versión anterior de la
        /// app se siga leyendo.
        var isFavorite: Bool?

        var difference: Double { myPoints - opponentPoints }

        /// Lo que pinta la barra: la probabilidad de ganar, y si no la hay,
        /// el reparto de puntos.
        var share: Double {
            if let winShare { return winShare }
            let total = myPoints + opponentPoints
            guard total > 0 else { return 0.5 }
            return myPoints / total
        }
    }

    /// Lo que no cambia durante el partido.
    var leagueName: String
    var week: Int
    var myTeam: String
    var opponentTeam: String
    /// De qué liga es esta actividad. Se puede seguir más de un partido a la
    /// vez —una actividad por liga— y al volver a abrir la app hay que saber
    /// cuál es cuál. Opcional porque una actividad encendida por la versión
    /// anterior sigue viva y no lo trae.
    var leagueID: String?
    /// Las fotos no caben en el estado (4 KB), así que viajan las direcciones
    /// y la vista lee el archivo que la app dejó en el grupo de apps.
    var myAvatarURL: String?
    var opponentAvatarURL: String?
}

extension MatchupSnapshot {
    /// Lo fijo de la Live Activity a partir del marcador.
    func activityAttributes(leagueID: String) -> MatchupActivityAttributes {
        MatchupActivityAttributes(
            leagueName: leagueName,
            week: week,
            myTeam: me.name,
            opponentTeam: opponent?.name ?? "Sin rival",
            leagueID: leagueID,
            myAvatarURL: me.avatarURL?.absoluteString,
            opponentAvatarURL: opponent?.avatarURL?.absoluteString
        )
    }

    /// Lo variable, con la última anotación conocida.
    func activityState(lastPlay: ScoringPlay? = nil) -> MatchupActivityAttributes.ContentState {
        MatchupActivityAttributes.ContentState(
            myPoints: me.points,
            opponentPoints: opponentPoints,
            myStarters: me.startersCount,
            opponentStarters: opponent?.startersCount ?? 0,
            lastPlay: lastPlay ?? plays.first,
            updatedAt: updatedAt,
            winChanceText: projection?.percentText,
            winShare: projection?.winProbability,
            myProjection: projection?.mine,
            opponentProjection: projection?.theirs,
            isFavorite: (projection?.winProbability ?? 0.5) >= 0.5
        )
    }
}
