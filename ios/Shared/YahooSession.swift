//  YahooSession.swift
//  Hablar con Yahoo desde cualquier sitio: app, widget o refresco de fondo.
//
//  El login vive en la app (`YahooAuth`), porque abrir una ventana de Safari
//  necesita pantalla. Pero *usar* el token no: el widget y el refresco en
//  segundo plano también piden datos, y corren sin interfaz. Por eso el token y
//  las credenciales se guardan en el llavero compartido y esto los lee de ahí.
//
//  Es un actor porque renovar el token es una carrera esperando a pasar: tres
//  ligas refrescándose a la vez con el token caducado harían tres canjes, y
//  Yahoo invalida el refresh token anterior en cada canje.

import Foundation

struct YahooCredentials: Codable, Equatable {
    var clientID: String
    var clientSecret: String
    /// Yahoo obliga a declarar la dirección de vuelta al registrar la app.
    var redirectURI: String
    /// Qué permisos se piden. **Vacío a propósito.**
    ///
    /// El documentado para fantasy es `fspt-r` (lectura), pero Yahoo lo
    /// rechaza con "invalid scope" en las apps registradas hoy: su formulario
    /// de alta ya no ofrece el permiso de Fantasy Sports. Sin `scope`, Yahoo
    /// concede lo que tenga la app registrada, que es como funcionan la
    /// mayoría de sus integraciones.
    ///
    /// Se deja a mano para poder probar otro sin recompilar. Opcional en el
    /// archivo para que lo guardado por la versión anterior se siga leyendo.
    var scope: String?

    var isComplete: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty && !redirectURI.isEmpty
    }

    /// El scope ya limpio, o nada si no hay que mandarlo.
    var requestedScope: String? {
        guard let scope else { return nil }
        let limpio = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpio.isEmpty ? nil : limpio
    }

    /// Sin espacios ni saltos de línea alrededor.
    ///
    /// Copiar un secreto en un teléfono y pegarlo en un campo arrastra un
    /// espacio o un salto con muchísima facilidad, y ese carácter de más viaja
    /// escapado hasta Yahoo, que contesta "Invalid client secret" sin decir
    /// que el problema es un espacio.
    var sanitized: YahooCredentials {
        YahooCredentials(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            redirectURI: redirectURI.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: scope
        )
    }
}

struct YahooToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var accountName: String?
    /// Los permisos que Yahoo **concedió**, que no tienen por qué ser los
    /// pedidos. Es la única forma de saber si el token sirve para fantasy sin
    /// esperar a que una petición devuelva 401. Opcional para que un token
    /// guardado por la versión anterior se siga leyendo.
    var grantedScope: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

enum YahooError: LocalizedError {
    case notConnected
    case missingCredentials
    case refreshFailed(String)
    case badStatus(Int, String)
    case network(String)
    case unreadable(String)
    case leagueNotFound(String)
    case teamNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Todavía no has entrado en Yahoo.")
        case .missingCredentials:
            return String(localized: "Faltan el client id y el secreto de tu app de Yahoo.")
        case let .refreshFailed(detalle):
            return String(localized: "Yahoo no renovó la sesión: \(detalle). Vuelve a entrar.")
        case let .badStatus(codigo, detalle):
            return String(localized: "Yahoo respondió \(codigo): \(detalle)")
        case let .network(detalle):
            return String(localized: "No se pudo conectar con Yahoo: \(detalle)")
        case let .unreadable(que):
            return String(localized: "Yahoo devolvió algo que no se entiende (\(que)).")
        case let .leagueNotFound(clave):
            return String(localized: "No encuentro la liga \(clave) en tu cuenta de Yahoo.")
        case let .teamNotFound(clave):
            return String(localized: "No encuentro tu equipo en la liga \(clave).")
        }
    }
}

actor YahooSession {
    static let shared = YahooSession()

    static let credentialsKey = "yahoo.credentials"
    static let tokenKey = "yahoo.token"

    private let baseURL = URL(string: "https://fantasysports.yahooapis.com/fantasy/v2")!
    private let tokenURL = URL(string: "https://api.login.yahoo.com/oauth2/get_token")!
    private let session: URLSession

    /// Para poder mandarme qué devolvió Yahoo cuando algo no cuadre. Solo se
    /// escribe si alguien lo enciende desde Ajustes.
    private let dumpFileName = "yahoo-ultima-respuesta.json"

    init(timeout: TimeInterval = 20) {
        let configuracion = URLSessionConfiguration.default
        configuracion.timeoutIntervalForRequest = timeout
        configuracion.waitsForConnectivity = false
        configuracion.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuracion)
    }

    nonisolated var isConnected: Bool {
        KeychainStore.read(YahooToken.self, for: Self.tokenKey) != nil
    }

    // MARK: - Petición

    /// Un GET autenticado. `path` va sin la barra inicial y sin `?format=json`:
    /// eso lo pone esto.
    func get(_ path: String) async throws -> JSONValue {
        let datos = try await raw(path)
        guard let arbol = JSONValue.parse(datos) else {
            throw YahooError.unreadable(path)
        }
        return arbol
    }

    private func raw(_ path: String, reintentando: Bool = false) async throws -> Data {
        let token = try await validToken()

        // Yahoo usa `;clave=valor` como separador de parámetros de ruta, así
        // que el `?` solo lleva el formato.
        let limpio = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let separador = limpio.contains("?") ? "&" : "?"
        guard let url = URL(string: "\(baseURL.absoluteString)/\(limpio)\(separador)format=json") else {
            throw YahooError.network("ruta no válida: \(path)")
        }

        var peticion = URLRequest(url: url)
        peticion.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        peticion.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (datos, respuesta) = try await session.data(for: peticion)
            let codigo = (respuesta as? HTTPURLResponse)?.statusCode ?? 0

            // 401 con el token recién renovado no se arregla reintentando.
            if codigo == 401, !reintentando {
                try await refresh(force: true)
                return try await raw(path, reintentando: true)
            }
            guard (200..<300).contains(codigo) else {
                // El cuerpo dice qué falta; el número solo, no.
                let cuerpo = (String(data: datos, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let permisos = KeychainStore.read(YahooToken.self, for: Self.tokenKey)?
                    .grantedScope ?? "ninguno"
                let explicacion = cuerpo.isEmpty ? path : "\(path) — \(cuerpo.prefix(300))"
                throw YahooError.badStatus(codigo, "\(explicacion) · permisos del token: \(permisos)")
            }
            dump(datos)
            return datos
        } catch let error as YahooError {
            throw error
        } catch {
            throw YahooError.network(error.localizedDescription)
        }
    }

    // MARK: - Token

    private func validToken() async throws -> YahooToken {
        guard let guardado = KeychainStore.read(YahooToken.self, for: Self.tokenKey) else {
            throw YahooError.notConnected
        }
        guard guardado.isExpired else { return guardado }
        try await refresh()
        guard let renovado = KeychainStore.read(YahooToken.self, for: Self.tokenKey) else {
            throw YahooError.notConnected
        }
        return renovado
    }

    /// Canjea el refresh token por uno nuevo. Al ser un actor, dos ligas que
    /// lleguen a la vez con el token caducado se ponen en cola y la segunda se
    /// encuentra el trabajo hecho.
    private func refresh(force: Bool = false) async throws {
        guard let actual = KeychainStore.read(YahooToken.self, for: Self.tokenKey) else {
            throw YahooError.notConnected
        }
        if !force, !actual.isExpired { return }
        guard let credenciales = KeychainStore.read(YahooCredentials.self, for: Self.credentialsKey),
              credenciales.isComplete else {
            throw YahooError.missingCredentials
        }
        guard let refrescar = actual.refreshToken else {
            throw YahooError.refreshFailed("no hay refresh token")
        }

        let campos: [String: String] = [
            "redirect_uri": credenciales.sanitized.redirectURI,
            "grant_type": "refresh_token",
            "refresh_token": refrescar,
        ]

        // Las dos formas de identificarse, igual que en el login.
        var datos = Data()
        var detalle = "sin detalle"
        for conBasic in [true, false] {
            let peticion = YahooSession.tokenRequest(
                url: tokenURL, fields: campos, credentials: credenciales, useBasic: conBasic
            )
            let (cuerpo, respuesta): (Data, URLResponse)
            do {
                (cuerpo, respuesta) = try await session.data(for: peticion)
            } catch {
                throw YahooError.network(error.localizedDescription)
            }
            if let http = respuesta as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                datos = cuerpo
                detalle = ""
                break
            }
            detalle = String(data: cuerpo, encoding: .utf8) ?? "sin detalle"
        }
        guard detalle.isEmpty else { throw YahooError.refreshFailed(detalle) }

        struct Respuesta: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            let scope: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case scope
            }
        }
        guard let nueva = try? JSONDecoder().decode(Respuesta.self, from: datos) else {
            throw YahooError.refreshFailed("respuesta inesperada")
        }
        let nuevo = YahooToken(
            accessToken: nueva.accessToken,
            // Yahoo no siempre devuelve uno nuevo: si no viene, sigue valiendo
            // el de antes, y perderlo obligaría a volver a entrar a mano.
            refreshToken: nueva.refreshToken ?? actual.refreshToken,
            expiresAt: nueva.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            accountName: actual.accountName,
            grantedScope: nueva.scope ?? actual.grantedScope
        )
        KeychainStore.save(nuevo, for: Self.tokenKey)
    }

    /// La petición de canje de token, que usan tanto el login de la app como
    /// la renovación de aquí.
    ///
    /// `useBasic` decide cómo se identifica la app. Yahoo documenta la
    /// cabecera `Authorization: Basic`, pero también hay integraciones que le
    /// mandan el client id y el secreto en el cuerpo; cuál acepta depende de
    /// cómo esté registrada. Se prueba primero la documentada y, si la rechaza,
    /// la otra: así una sola compilación da la respuesta.
    static func tokenRequest(
        url: URL,
        fields: [String: String],
        credentials: YahooCredentials,
        useBasic: Bool
    ) -> URLRequest {
        let limpias = credentials.sanitized
        var campos = fields
        var peticion = URLRequest(url: url)
        peticion.httpMethod = "POST"
        peticion.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        if useBasic {
            let pareja = "\(limpias.clientID):\(limpias.clientSecret)"
            let codificada = Data(pareja.utf8).base64EncodedString()
            peticion.setValue("Basic \(codificada)", forHTTPHeaderField: "Authorization")
        } else {
            campos["client_id"] = limpias.clientID
            campos["client_secret"] = limpias.clientSecret
        }
        peticion.httpBody = formBody(campos)
        return peticion
    }

    /// `application/x-www-form-urlencoded` de verdad: los espacios son `+` y
    /// hay que escapar todo lo que no sea alfanumérico o `-._~`.
    static func formBody(_ campos: [String: String]) -> Data? {
        var permitidos = CharacterSet.alphanumerics
        permitidos.insert(charactersIn: "-._~")
        return campos
            .map { clave, valor in
                let escapado = valor.addingPercentEncoding(withAllowedCharacters: permitidos) ?? valor
                return "\(clave)=\(escapado)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    // MARK: - Diagnóstico

    /// Guarda la última respuesta para poder mirarla cuando algo no cuadre.
    /// Apagado por defecto: son datos de la liga de quien use la app.
    private func dump(_ datos: Data) {
        guard SharedStore.defaults.bool(forKey: "yahooDebugDump") else { return }
        let destino = SharedStore.containerURL.appendingPathComponent(dumpFileName)
        try? datos.write(to: destino, options: .atomic)
    }

    nonisolated var dumpURL: URL {
        SharedStore.containerURL.appendingPathComponent("yahoo-ultima-respuesta.json")
    }
}
