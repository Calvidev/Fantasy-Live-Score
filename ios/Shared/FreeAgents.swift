//  FreeAgents.swift
//  Quién está libre en tu liga y merece la pena.
//
//  Todo sale de datos que la app ya sabe pedir: quién está ocupado (los rosters
//  de tu liga), qué se espera de cada jugador (las proyecciones) y a quién está
//  fichando la gente (las tendencias de Sleeper, que son el pulso de toda su
//  comunidad, no solo de tu liga).

import Foundation

struct FreeAgent: Identifiable, Hashable {
    var playerID: String
    var name: String
    var position: String?
    var team: String?
    var projected: Double
    /// Cuánta gente lo ha fichado en las últimas 24 horas.
    var adds: Int
    var injury: String?

    var id: String { playerID }

    var subtitle: String {
        [position, team].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var injuryLabel: String? {
        guard let injury, !injury.isEmpty else { return nil }
        return InjuryChange.label(injury)
    }

    var injuryIsSevere: Bool { InjuryChange.severity(injury) >= 3 }

    /// La nota con la que se ordenan: lo que se espera que anote, más un
    /// empujón por lo que se le está fichando. El logaritmo evita que un
    /// jugador con 40.000 fichajes aplaste a uno con 3.000: la diferencia
    /// entre "nadie lo quiere" y "lo quiere todo el mundo" importa mucho más
    /// que entre "mucho" y "muchísimo".
    var score: Double {
        projected + 3 * log10(Double(max(1, adds)))
    }
}

extension MatchupService {
    /// Los mejores agentes libres de tu liga.
    func freeAgents(
        league: LeagueConfig,
        limit: Int = 40
    ) async throws -> [FreeAgent] {
        // De momento solo Sleeper: esto se apoya en su catálogo de jugadores y
        // en lo que se ficha en toda la plataforma, que no tiene equivalente.
        guard league.platform == .sleeper else {
            throw SleeperError.hostUnsupported(league.platform.title)
        }
        let leagueID = league.leagueID.trimmingCharacters(in: .whitespaces)
        guard !leagueID.isEmpty else { throw SleeperError.leagueNotSet }

        async let leagueTask = api.league(leagueID)
        async let rostersTask = api.rosters(leagueID: leagueID)
        async let trendingTask = api.trending(kind: "add")
        let reglas = (try? await leagueTask)?.scoringSettings
        let rosters = try await rostersTask
        // Las tendencias son un extra: si fallan, la lista sale igual.
        let trending = (try? await trendingTask) ?? [:]

        var ocupados = Set<String>()
        for roster in rosters {
            for playerID in roster.players ?? [] { ocupados.insert(playerID) }
        }

        let catalog = await PlayerCatalog.shared.cached()
        let projections = await ProjectionStore.shared.cached()
        guard !catalog.isEmpty else { return [] }

        // Solo posiciones de fantasy: nadie ficha a un tackle ofensivo.
        let posiciones: Set<String> = ["QB", "RB", "WR", "TE", "K", "DEF"]

        var candidatos: [FreeAgent] = []
        for (playerID, jugador) in catalog {
            guard !ocupados.contains(playerID) else { continue }
            let posicion = (jugador.position ?? "").uppercased()
            guard posiciones.contains(posicion) else { continue }

            let proyectado = projections?.projected(for: playerID, scoring: reglas) ?? 0
            let fichajes = trending[playerID] ?? 0
            // Sin proyección ni movimiento no hay nada que recomendar.
            guard proyectado > 0 || fichajes > 0 else { continue }

            candidatos.append(
                FreeAgent(
                    playerID: playerID,
                    name: jugador.name,
                    position: jugador.position,
                    team: jugador.team,
                    projected: proyectado,
                    adds: fichajes,
                    injury: jugador.injuryStatus
                )
            )
        }

        return Array(candidatos.sorted { $0.score > $1.score }.prefix(limit))
    }
}
