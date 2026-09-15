//  Projections.swift
//  Lo que se espera que anote cada jugador esta jornada.
//
//  Es la pieza que falta para poder decir "vas ganando pero vas a perder":
//  sin proyecciones, un marcador a mitad de domingo no significa gran cosa.
//
//  Se descarga y se guarda igual que las estadísticas: solo desde la app, en
//  el grupo de apps, y el widget lee el archivo.

import Foundation

struct Projections: Codable {
    /// player_id -> estadísticas proyectadas ("rec": 5.2, "rec_yd": 68.4…).
    ///
    /// Se guardan crudas a propósito: los puntos dependen de cómo puntúe cada
    /// liga, y dos ligas del mismo usuario pueden puntuar distinto.
    var byPlayer: [String: [String: Double]]
    var season: String
    var week: Int
    var savedAt: Date

    /// Los puntos que ese jugador sacaría **en esta liga**.
    ///
    /// Es lo mismo que hace Sleeper: multiplicar cada estadística por lo que
    /// vale en la liga y sumar. Usar `pts_ppr` a secas se desviaba varios
    /// puntos por equipo en cuanto la liga no era PPR entera.
    func projected(for playerID: String, scoring: [String: Double]?) -> Double? {
        guard let stats = byPlayer[playerID] else { return nil }

        if let scoring, !scoring.isEmpty {
            var total = 0.0
            for (estadistica, cantidad) in stats {
                guard let puntosPorUnidad = scoring[estadistica] else { continue }
                total += cantidad * puntosPorUnidad
            }
            if total != 0 { return total }
        }

        // Sin reglas de liga (o una liga que no puntúa nada de lo proyectado),
        // el total precalculado de Sleeper es mejor que nada.
        return stats["pts_ppr"] ?? stats["pts_half_ppr"] ?? stats["pts_std"]
    }
}

extension Projections {
    /// Una jornada suelta, sin pasar por la caché. Ver `WeekStats.fetch`.
    static func fetch(season: String, week: Int) async -> Projections? {
        guard
            let crudas: [String: [String: Double]] = try? await SleeperAPI.shared
                .get("/projections/nfl/regular/\(season)/\(week)")
        else { return nil }
        return Projections(byPlayer: crudas, season: season, week: week, savedAt: Date())
    }
}

actor ProjectionStore {
    static let shared = ProjectionStore()

    private let fileName = "projections.json"
    /// Las proyecciones cambian poco dentro de una jornada: con una vez cada
    /// seis horas sobra.
    private let maxAge: TimeInterval = 60 * 60 * 6
    private var memory: Projections?

    private var fileURL: URL {
        SharedStore.containerURL.appendingPathComponent(fileName)
    }

    func cached() -> Projections? {
        if let memory { return memory }
        guard
            let data = try? Data(contentsOf: fileURL),
            let guardadas = try? SharedJSON.decoder.decode(Projections.self, from: data)
        else {
            return nil
        }
        memory = guardadas
        return guardadas
    }

    @discardableResult
    func refreshIfNeeded(season: String, week: Int) async -> Projections? {
        if let guardadas = cached(),
           guardadas.season == season,
           guardadas.week == week,
           Date().timeIntervalSince(guardadas.savedAt) < maxAge {
            return guardadas
        }

        guard
            let crudas: [String: [String: Double]] = try? await SleeperAPI.shared
                .get("/projections/nfl/regular/\(season)/\(week)")
        else {
            return cached()
        }

        let nuevas = Projections(
            byPlayer: crudas, season: season, week: week, savedAt: Date()
        )
        memory = nuevas
        if let data = try? SharedJSON.encoder.encode(nuevas) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return nuevas
    }
}
