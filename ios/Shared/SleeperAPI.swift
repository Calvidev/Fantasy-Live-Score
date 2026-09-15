//  SleeperAPI.swift
//  Cliente de la API pública de Sleeper (lectura, sin autenticación).

import Foundation

enum SleeperError: LocalizedError {
    case badStatus(Int, String)
    case network(String)
    case decoding(String)
    case rosterNotFound(Int)
    case weekNotScheduled(Int)
    case hostUnsupported(String)
    case leagueNotSet
    case userNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code, path) where code == 404:
            return String(localized: "Sleeper no encuentra \(path). Revisa el id de la liga.")
        case let .badStatus(code, path):
            return String(localized: "Sleeper respondió \(code) en \(path).")
        case let .network(detail):
            return String(localized: "No se pudo conectar con Sleeper: \(detail)")
        case let .decoding(detail):
            return String(localized: "Sleeper devolvió algo inesperado: \(detail)")
        case let .rosterNotFound(rosterID):
            return String(localized: "El equipo \(rosterID) no juega esta jornada en esa liga.")
        case let .weekNotScheduled(week):
            return String(localized: "Sleeper todavía no ha puesto los enfrentamientos de la semana \(week).")
        case let .hostUnsupported(plataforma):
            return String(localized: "Todavía no se pueden leer ligas de \(plataforma).")
        case .leagueNotSet:
            return String(localized: "Todavía no has elegido liga y equipo.")
        case let .userNotFound(username):
            return String(localized: "Sleeper no conoce a «\(username)». Es tu nombre de usuario, no el correo.")
        }
    }
}

struct SleeperAPI {
    static let shared = SleeperAPI()

    private let baseURL = URL(string: "https://api.sleeper.app/v1")!
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        // La caché del sistema estorba en un marcador en vivo.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await raw(path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SleeperError.decoding("\(path) — \(error.localizedDescription)")
        }
    }

    func raw(_ path: String) async throws -> Data {
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: baseURL.absoluteString + suffix) else {
            throw SleeperError.network("ruta no válida: \(path)")
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SleeperError.badStatus(http.statusCode, path)
            }
            return data
        } catch let error as SleeperError {
            throw error
        } catch {
            throw SleeperError.network(error.localizedDescription)
        }
    }

    /// Descarga suelta (avatares del CDN, catálogo completo…).
    func download(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SleeperError.badStatus(http.statusCode, url.lastPathComponent)
            }
            return data
        } catch let error as SleeperError {
            throw error
        } catch {
            throw SleeperError.network(error.localizedDescription)
        }
    }

    // MARK: - Endpoints

    func state() async throws -> NFLState {
        try await get("/state/nfl")
    }

    /// Perfil por nombre de usuario. Es la puerta de entrada: de aquí sale el
    /// `user_id` con el que se listan sus ligas.
    func user(username: String) async throws -> SleeperUser {
        let limpio = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { throw SleeperError.userNotFound(username) }
        let escapado = limpio.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? limpio
        do {
            return try await get("/user/\(escapado)")
        } catch SleeperError.badStatus(let code, _) where code == 404 {
            throw SleeperError.userNotFound(limpio)
        } catch SleeperError.decoding(let detalle) {
            // Un usuario que no existe devuelve `null`, que no es un perfil.
            throw SleeperError.userNotFound(limpio + " — " + detalle)
        }
    }

    /// Las ligas de ese usuario en una temporada.
    func leagues(userID: String, season: String) async throws -> [LeagueSummary] {
        try await get("/user/\(userID)/leagues/nfl/\(season)")
    }

    func league(_ leagueID: String) async throws -> League {
        try await get("/league/\(leagueID)")
    }

    func users(leagueID: String) async throws -> [LeagueUser] {
        try await get("/league/\(leagueID)/users")
    }

    func rosters(leagueID: String) async throws -> [Roster] {
        try await get("/league/\(leagueID)/rosters")
    }

    func matchups(leagueID: String, week: Int) async throws -> [Matchup] {
        try await get("/league/\(leagueID)/matchups/\(week)")
    }

    /// Los jugadores que más se están fichando (o cortando) en Sleeper.
    /// Es el pulso de la comunidad entera, no solo de tu liga.
    func trending(kind: String = "add", lookbackHours: Int = 24, limit: Int = 100) async throws -> [String: Int] {
        struct Entrada: Decodable {
            let playerID: String
            let count: Int?
            enum CodingKeys: String, CodingKey {
                case playerID = "player_id"
                case count
            }
        }
        let entradas: [Entrada] = try await get(
            "/players/nfl/trending/\(kind)?lookback_hours=\(lookbackHours)&limit=\(limit)"
        )
        return Dictionary(
            entradas.map { ($0.playerID, $0.count ?? 0) },
            uniquingKeysWith: { primero, _ in primero }
        )
    }

    /// Catálogo completo de jugadores (~5 MB). Sleeper pide no bajarlo más de
    /// una vez al día: de eso se encarga `PlayerCatalog`.
    func playersCatalog() async throws -> [String: RawCatalogPlayer] {
        let data = try await raw("/players/nfl")
        do {
            return try JSONDecoder().decode([String: RawCatalogPlayer].self, from: data)
        } catch {
            throw SleeperError.decoding("catálogo de jugadores — \(error.localizedDescription)")
        }
    }
}
