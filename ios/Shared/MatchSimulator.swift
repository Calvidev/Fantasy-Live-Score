//  MatchSimulator.swift
//  Anotaciones de mentira para probar sin esperar al domingo.
//
//  No falsea la interfaz: fabrica un marcador nuevo con los puntos sumados y
//  lo mete por la misma puerta que los datos reales, así que lo que se prueba
//  es `ScoringDetector`, la Live Activity y las notificaciones de verdad.

import Foundation

enum MatchSimulator {
    /// Lo que suele valer una jugada, para el menú de pruebas.
    enum Play: String, CaseIterable, Identifiable {
        case touchdown
        case fieldGoal
        case reception

        var id: String { rawValue }

        var points: Double {
            switch self {
            case .touchdown: return 6.0
            case .fieldGoal: return 3.0
            case .reception: return 1.4
            }
        }

        var title: String {
            switch self {
            case .touchdown: return "Touchdown (+6)"
            case .fieldGoal: return "Field goal (+3)"
            // Por debajo del mínimo para avisar: sirve justo para comprobar
            // que se mueve el marcador y NO llega notificación.
            case .reception: return "Recepción (+1.4 · sin aviso)"
            }
        }
    }

    /// Suma puntos a un titular al azar y devuelve el marcador resultante.
    /// `mine == nil` deja que le toque a cualquiera de los dos equipos.
    static func apply(
        _ play: Play,
        to snapshot: MatchupSnapshot,
        mine: Bool? = nil,
        now: Date = Date()
    ) -> MatchupSnapshot? {
        let esMio = mine ?? Bool.random()

        // Candidatos: los huecos con jugador en el lado elegido.
        let indices = snapshot.lineup.indices.filter { indice in
            esMio ? snapshot.lineup[indice].mine != nil : snapshot.lineup[indice].theirs != nil
        }
        guard let elegido = indices.randomElement() else { return nil }

        var copia = snapshot
        if esMio {
            guard var jugador = copia.lineup[elegido].mine else { return nil }
            jugador.points += play.points
            copia.lineup[elegido].mine = jugador
            copia.me.points += play.points
        } else {
            guard var jugador = copia.lineup[elegido].theirs else { return nil }
            jugador.points += play.points
            copia.lineup[elegido].theirs = jugador
            copia.opponent?.points += play.points
        }
        copia.updatedAt = now
        copia.isStale = false
        copia.projection = WinProbability.compute(for: copia)
        return copia
    }
}
