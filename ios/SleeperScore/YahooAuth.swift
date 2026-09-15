//  YahooAuth.swift
//  Login de Yahoo con OAuth 2.0.
//
//  Yahoo, al contrario que Sleeper, sí exige identificarse. Hay que registrar
//  una app en developer.yahoo.com para conseguir un client id y un secreto; no
//  vienen en el código porque un secreto dentro de una app de iPhone no es un
//  secreto (cualquiera lo saca del binario). Se piden una vez y se guardan en
//  el llavero.
//
//  Esto solo inicia sesión y guarda el token. Leerlo y pedir datos es cosa de
//  `Shared/YahooSession`, que corre también sin interfaz: el widget y el
//  refresco de fondo necesitan los mismos datos y no pueden abrir una ventana.
//  Por eso `YahooCredentials` y `YahooToken` viven en Shared y no aquí.

import AuthenticationServices
import Foundation
import UIKit

enum YahooAuthError: LocalizedError {
    case missingCredentials
    case cancelled
    case badRedirect
    case tokenExchange(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Faltan el client id y el secreto de tu app de Yahoo."
        case .cancelled:
            return "Has cerrado la ventana de Yahoo sin terminar."
        case .badRedirect:
            return "Yahoo no devolvió el código de autorización."
        case let .tokenExchange(detalle):
            return "Yahoo rechazó el canje del token: \(detalle)"
        }
    }
}

@MainActor
final class YahooAuth: NSObject, ObservableObject {
    static let credentialsKey = "yahoo.credentials"
    static let tokenKey = "yahoo.token"

    @Published private(set) var token: YahooToken?
    @Published var credentials: YahooCredentials

    /// La ventana sobre la que se presenta el login. Se captura antes de
    /// arrancar la sesión para no tener que buscarla desde fuera del hilo
    /// principal, que es donde el sistema pide el ancla.
    private nonisolated(unsafe) var anchor: ASPresentationAnchor?

    private let authorizeURL = URL(string: "https://api.login.yahoo.com/oauth2/request_auth")!
    private let tokenURL = URL(string: "https://api.login.yahoo.com/oauth2/get_token")!

    override init() {
        credentials = KeychainStore.read(YahooCredentials.self, for: Self.credentialsKey)
            ?? YahooCredentials(
                clientID: "", clientSecret: "",
                redirectURI: AppConfig.yahooRedirectURI,
                scope: nil
            )
        token = KeychainStore.read(YahooToken.self, for: Self.tokenKey)
        super.init()
    }

    var isConnected: Bool { token != nil }

    func saveCredentials() {
        credentials = credentials.sanitized
        KeychainStore.save(credentials, for: Self.credentialsKey)
    }

    // MARK: - Entrar

    /// El esquema por el que vuelve el código a la app.
    ///
    /// No sale de la dirección de vuelta a propósito. Yahoo **solo** admite
    /// direcciones `https://` —ni esquemas propios ni `oob`, las dos cosas las
    /// rechaza al registrar la app—, así que la vuelta es una página web que no
    /// hace más que rebotar aquí: `docs/yahoo.html`, servida por GitHub Pages.
    /// La página lee el código de su propia barra de direcciones y salta a
    /// `sleeperscore://yahoo?code=…`, que es lo que caza la sesión.
    static let callbackScheme = "sleeperscore"

    /// La dirección de vuelta no es un esquema propio, así que hay que esperar
    /// el rebote de la página (o pegar el código a mano).
    var usesPastedCode: Bool {
        let destino = credentials.redirectURI.trimmingCharacters(in: .whitespaces).lowercased()
        return destino == "oob" || destino.isEmpty
    }

    /// La página de Yahoo a la que hay que ir. Se expone porque con `oob` la
    /// abre la propia pantalla de ajustes, no una sesión de autenticación.
    func authorizationURL() throws -> URL {
        guard credentials.isComplete else { throw YahooAuthError.missingCredentials }
        var componentes = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        let limpias = credentials.sanitized
        var parametros = [
            URLQueryItem(name: "client_id", value: limpias.clientID),
            URLQueryItem(name: "redirect_uri", value: limpias.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]
        // Solo si hay uno puesto. Mandar `fspt-r` —el documentado para
        // fantasy— hace que Yahoo conteste "invalid scope" en las apps
        // registradas hoy: su formulario de alta ya no ofrece ese permiso.
        // Sin `scope`, concede lo que tenga la app.
        if let scope = credentials.requestedScope {
            parametros.append(URLQueryItem(name: "scope", value: scope))
        }
        componentes.queryItems = parametros
        guard let url = componentes.url else { throw YahooAuthError.badRedirect }
        return url
    }

    /// El código que Yahoo enseña en pantalla con `oob`, pegado a mano.
    func connect(pastedCode: String) async throws {
        let limpio = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { throw YahooAuthError.badRedirect }
        saveCredentials()
        try await exchange(code: limpio)
    }

    func signIn() async throws {
        guard credentials.isComplete else { throw YahooAuthError.missingCredentials }
        saveCredentials()

        let componentes = try authorizationURL()

        anchor = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow

        let vuelta = try await presentLogin(url: componentes)
        guard
            let items = URLComponents(url: vuelta, resolvingAgainstBaseURL: false)?.queryItems,
            let codigo = items.first(where: { $0.name == "code" })?.value
        else {
            throw YahooAuthError.badRedirect
        }
        try await exchange(code: codigo)
    }

    func signOut() {
        token = nil
        KeychainStore.delete(Self.tokenKey)
        SharedStore.disconnect(.yahoo)
    }

    /// Renueva el token cuando caduca. Yahoo los da con una hora de vida.
    func refreshIfNeeded() async {
        guard let actual = token, actual.isExpired, let refresco = actual.refreshToken else { return }
        try? await exchange(refreshToken: refresco)
    }

    // MARK: - Interno

    private func presentLogin(url: URL) async throws -> URL {
        // Con una vuelta https, lo que hay que cazar es el salto que da la
        // página de rebote, no el https en sí.
        let declarado = URL(string: credentials.redirectURI)?.scheme?.lowercased()
        let esquema = (declarado == nil || declarado == "http" || declarado == "https")
            ? Self.callbackScheme
            : declarado
        return try await withCheckedThrowingContinuation { continuation in
            let sesion = ASWebAuthenticationSession(
                url: url, callbackURLScheme: esquema
            ) { vuelta, error in
                if let vuelta {
                    continuation.resume(returning: vuelta)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: YahooAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? YahooAuthError.badRedirect)
                }
            }
            sesion.presentationContextProvider = self
            sesion.prefersEphemeralWebBrowserSession = false
            sesion.start()
        }
    }

    private func exchange(code: String? = nil, refreshToken: String? = nil) async throws {
        var campos: [String: String] = [
            "redirect_uri": credentials.sanitized.redirectURI,
        ]
        if let code {
            campos["grant_type"] = "authorization_code"
            campos["code"] = code
        } else if let refreshToken {
            campos["grant_type"] = "refresh_token"
            campos["refresh_token"] = refreshToken
        }

        // Primero como lo documenta Yahoo (cabecera Basic) y, si lo rechaza,
        // con el secreto en el cuerpo. Depende de cómo esté registrada la app,
        // y probar las dos aquí ahorra una compilación entera.
        var datos = Data()
        var detalle = "sin detalle"
        for conBasic in [true, false] {
            let peticion = YahooSession.tokenRequest(
                url: tokenURL, fields: campos, credentials: credentials, useBasic: conBasic
            )
            let (cuerpo, respuesta) = try await URLSession.shared.data(for: peticion)
            if let http = respuesta as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                datos = cuerpo
                detalle = ""
                break
            }
            let texto = String(data: cuerpo, encoding: .utf8) ?? "sin detalle"
            detalle = conBasic ? "con cabecera Basic: \(texto)" : "\(detalle) · en el cuerpo: \(texto)"
        }
        guard detalle.isEmpty else {
            throw YahooAuthError.tokenExchange(detalle)
        }

        struct Respuesta: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            let xoauthYahooGuid: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case xoauthYahooGuid = "xoauth_yahoo_guid"
            }
        }

        let decodificada = try JSONDecoder().decode(Respuesta.self, from: datos)
        let nuevo = YahooToken(
            accessToken: decodificada.accessToken,
            refreshToken: decodificada.refreshToken ?? refreshToken,
            expiresAt: decodificada.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            accountName: decodificada.xoauthYahooGuid ?? token?.accountName
        )
        token = nuevo
        KeychainStore.save(nuevo, for: Self.tokenKey)
        SharedStore.connect(.yahoo, accountName: nuevo.accountName ?? "Cuenta de Yahoo")
    }
}

extension YahooAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
