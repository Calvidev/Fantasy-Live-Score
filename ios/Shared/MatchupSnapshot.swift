//  MatchupSnapshot.swift
//  La foto del enfrentamiento: lo único que la app y el widget pintan.
//
//  Es `Codable` a propósito. Se guarda entera en el grupo de apps, así que el
//  widget puede enseñar el último marcador conocido aunque no haya red.

import Foundation

struct TeamSide: Codable, Hashable, Identifiable {
    var rosterID: Int
    var name: String
    var avatarURL: URL?
    var avatarData: Data?
    var points: Double
    var startersCount: Int
    var record: String?

    var id: Int { rosterID }
}

struct PlayerLine: Codable, Hashable, Identifiable {
    var playerID: String
    var points: Double
    var name: String?
    var position: String?
    var team: String?
    /// "6 rec · 88 yds · 1 TD". Opcional: solo hay línea si se han descargado
    /// las estadísticas de la jornada.
    var stats: String?
    /// Lo que se espera que anote en la jornada.
    var projected: Double?
    /// "Questionable", "Out"… Nil cuando está sano.
    var injury: String?
    /// True cuando el partido de su equipo ya ha terminado: entonces lo que
    /// lleva anotado es lo definitivo y no le queda nada por sumar.
    var gameFinished: Bool?
    /// Qué fracción del partido le queda por delante, de 1 a 0. Es lo que
    /// permite encoger su proyección según avanza el reloj, como hace Sleeper.
    /// Nil cuando no sabemos en qué punto va el partido.
    var gameRemaining: Double?

    var id: String { playerID }

    /// "T. Hill · WR KC" cuando hay catálogo; si no, algo legible igualmente.
    var subtitle: String {
        [position, team].compactMap { $0 }.joined(separator: " ")
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Jugador \(playerID)"
    }

    /// "Duda", "Fuera"… en corto, para la etiqueta de al lado del nombre.
    var injuryLabel: String? {
        guard let injury, !injury.isEmpty else { return nil }
        return InjuryChange.label(injury)
    }

    /// Lesiones que impiden jugar: se pintan en rojo, no en naranja.
    var injuryIsSevere: Bool {
        InjuryChange.severity(injury) >= 3
    }
}

/// Un hueco de la alineación con los dos jugadores que lo ocupan.
struct LineupRow: Codable, Hashable, Identifiable {
    var index: Int
    var slot: String
    var mine: PlayerLine?
    var theirs: PlayerLine?

    var id: Int { index }

    var slotLabel: String {
        switch slot.uppercased() {
        case "SUPER_FLEX": return "SFLX"
        case "REC_FLEX": return "RFLX"
        case "IDP_FLEX": return "IDP"
        default: return slot.uppercased()
        }
    }
}

struct MatchupSnapshot: Codable, Hashable {
    var leagueName: String
    var week: Int
    var me: TeamSide
    var opponent: TeamSide?
    var lineup: [LineupRow]
    var updatedAt: Date
    /// True cuando estos datos salen de la caché porque la descarga falló.
    var isStale: Bool
    /// Últimas anotaciones detectadas. Opcional a propósito: así una caché
    /// escrita por una versión anterior de la app se sigue leyendo.
    var recentPlays: [ScoringPlay]?
    /// Marcador final esperado y probabilidad de ganar.
    var projection: MatchupProjection?
    /// Cómo puntúa esta liga: "PPR", "media PPR", "estándar"… Se enseña junto
    /// a la proyección para poder comprobar de un vistazo que la app está
    /// usando las reglas de tu liga y no unas genéricas.
    var scoringLabel: String?
    /// Tu banquillo, para poder decir qué te dejaste sin alinear.
    var bench: [PlayerLine]?
    /// Lo que costó no alinear lo mejor posible.
    var benchReport: BenchReport?
    /// La jornada que Sleeper da por buena ahora mismo. Con `week` dice si lo
    /// que se está mirando es la jornada en curso o una pasada, y hasta dónde
    /// llega el selector de semanas. Opcional: lo guardado por la versión
    /// anterior no lo trae.
    var liveWeek: Int?

    /// Se está mirando una jornada que ya terminó.
    var isPastWeek: Bool {
        guard let liveWeek else { return false }
        return week < liveWeek
    }

    /// Las anotaciones, sin tener que desenvolver el opcional en cada vista.
    var plays: [ScoringPlay] { recentPlays ?? [] }

    var opponentPoints: Double { opponent?.points ?? 0 }

    var difference: Double { me.points - opponentPoints }

    /// Reparto de los puntos ya anotados. Sirve para poco en mitad de la
    /// jornada —un pateador puede dejarlo en 76 %— pero es el respaldo cuando
    /// no hay proyección.
    var myShare: Double {
        let total = me.points + opponentPoints
        guard total > 0 else { return 0.5 }
        return me.points / total
    }

    /// Lo que pinta la barra: la probabilidad de ganar.
    ///
    /// Antes repartía los puntos actuales y contradecía al número de al lado:
    /// con 3.2 a 1.0 la barra decía 76 % mientras la probabilidad era 51 %.
    /// Lo que la gente lee en esa barra es "cómo voy", y eso es la
    /// probabilidad, no quién lleva más puntos a media tarde del domingo.
    var barShare: Double {
        projection?.winProbability ?? myShare
    }

    var isLeading: Bool { difference >= 0 }

    /// Hay partido en marcha (algo se está moviendo): sirve para decidir cada
    /// cuánto pedirle a WidgetKit que refresque.
    var looksLive: Bool { me.points > 0 || opponentPoints > 0 }

    static func placeholder() -> MatchupSnapshot {
        MatchupSnapshot(
            leagueName: "Tu liga de Sleeper",
            week: 1,
            me: TeamSide(
                rosterID: 1, name: "Tu equipo", avatarURL: nil, avatarData: nil,
                points: 88.4, startersCount: 9, record: "3-1"
            ),
            opponent: TeamSide(
                rosterID: 2, name: "Rival", avatarURL: nil, avatarData: nil,
                points: 74.2, startersCount: 9, record: "2-2"
            ),
            lineup: [],
            updatedAt: Date(),
            isStale: false,
            recentPlays: nil
        )
    }
}

extension Double {
    /// Los puntos de fantasy se leen siempre con un decimal.
    var fantasyPoints: String {
        String(format: "%.1f", self)
    }

    var signedFantasyPoints: String {
        (self >= 0 ? "+" : "") + fantasyPoints
    }
}
