//  AccountsView.swift
//  El menú de cuentas: con qué plataforma entras.
//
//  Sleeper y Yahoo se pueden conectar. ESPN y NFL.com salen apagadas a
//  propósito: están para decir "esto viene después", no para engañar.

import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: ScoreboardModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var yahoo = YahooAuth()

    @State private var showingYahoo = false
    @State private var showingYahooLeagues = false
    @State private var showingPaywall = false
    @State private var catalogDate: Date?
    @State private var isRefreshingCatalog = false
    /// Cambia al conectar una cuenta o al volver de la pantalla de Pro; se lee
    /// en cada dibujado en vez de guardarse, que era lo que se quedaba viejo.
    @State private var revision = 0
    @State private var autoStart = SharedStore.autoStartLiveActivity

    var body: some View {
        NavigationStack {
            Form {
                leaguesSection
                accountsSection
                lockScreenSection
                planSection
                testingSection
                widgetSection
                catalogSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Cuentas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView().preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showingYahoo) {
                YahooLoginView(auth: yahoo)
                    .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showingYahooLeagues) {
                YahooLeaguesView()
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
            .task {
                catalogDate = await PlayerCatalog.shared.savedAt
            }
            .onChange(of: showingYahoo) { _, abierto in
                if !abierto { revision += 1 }
            }
            .onChange(of: showingPaywall) { _, abierto in
                if !abierto { revision += 1 }
            }
            .onChange(of: model.book) { _, _ in
                revision += 1
            }
        }
    }

    /// Estado actual de las cuentas conectadas. `revision` fuerza a releerlo.
    private var connections: [HostKind: HostConnection] {
        _ = revision
        return SharedStore.connections()
    }

    private var plan: Plan {
        _ = revision
        return EntitlementStore.current.plan
    }

    // MARK: - Mis ligas

    @ViewBuilder
    private var leaguesSection: some View {
        if !model.book.leagues.isEmpty {
            Section {
                ForEach(model.book.leagues) { liga in
                    Button {
                        model.activate(liga)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: liga.platform.symbol)
                                .foregroundStyle(liga.platform.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(liga.displayName)
                                    .foregroundStyle(.primary)
                                if let equipo = liga.teamName {
                                    Text(equipo)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if liga.id == model.book.activeID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .onDelete { indices in
                    for indice in indices {
                        model.remove(model.book.leagues[indice])
                    }
                }
            } header: {
                Text("Mis ligas")
            } footer: {
                Text(model.book.leagues.count > 1
                     ? "Toca una para verla en el marcador; desliza para quitarla."
                     : "Añade otra desde Sleeper, aquí abajo.")
            }
        }
    }

    // MARK: - Pantalla de bloqueo

    private var lockScreenSection: some View {
        Section {
            Toggle("Encenderla sola al empezar el partido", isOn: $autoStart)
                .onChange(of: autoStart) { _, nuevo in
                    SharedStore.autoStartLiveActivity = nuevo
                }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("La Live Activity se enciende cuando alguien anota, siempre que la app esté abierta en ese momento: iOS no deja arrancarla desde segundo plano sin notificaciones push, que piden cuenta de desarrollador de pago. También puedes encenderla a mano desde el marcador.")
        }
    }

    // MARK: - Plan

    private var planSection: some View {
        Section {
            Button {
                showingPaywall = true
            } label: {
                HStack {
                    Label("Plan \(plan.title)", systemImage: "sparkles")
                        .foregroundStyle(.primary)
                    Spacer()
                    if plan == .free {
                        Text("Ver Pro")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        } footer: {
            Text(plan == .free
                 ? "El plan gratis sigue una liga. Pro quita el límite."
                 : "Pro activo: ligas ilimitadas.")
        }
    }

    // MARK: - Plataformas

    private var accountsSection: some View {
        Section {
            NavigationLink {
                SleeperSettingsView()
                    .environmentObject(model)
            } label: {
                HostRow(host: .sleeper, connection: connections[.sleeper])
            }

            Button {
                showingYahoo = true
            } label: {
                HostRow(host: .yahoo, connection: connections[.yahoo])
            }

            // Con la sesión ya iniciada, lo que hace falta es elegir liga.
            if connections[.yahoo] != nil {
                Button {
                    showingYahooLeagues = true
                } label: {
                    Label("Añadir una liga de Yahoo", systemImage: "plus.circle")
                        .foregroundStyle(Theme.accent)
                }
            }

            ForEach(HostKind.allCases.filter { !$0.isAvailable }) { host in
                HostRow(host: host, connection: nil)
                    .opacity(0.45)
                    // No es solo estética: no se puede tocar.
                    .allowsHitTesting(false)
                    .accessibilityHint("Todavía no disponible")
            }
        } header: {
            Text("Dónde juegas")
        } footer: {
            Text("ESPN y NFL.com llegarán más adelante: sus API no son públicas y hace falta resolver antes cómo entrar en cada una.")
        }
    }

    // MARK: - Pruebas

    /// Anotaciones de mentira para probar la Live Activity y los avisos sin
    /// esperar a que se juegue la jornada. Solo en compilaciones de depuración.
    @ViewBuilder
    private var testingSection: some View {
        #if DEBUG
        Section {
            if model.pendingSimulation {
                Label("Anota en 2 segundos… cierra la app", systemImage: "timer")
                    .foregroundStyle(Theme.accent)
            }
            Button("Anota tu jugador (+6)") {
                Task { await model.simulate(.touchdown, mine: true) }
            }
            Button("Anota el rival (+6)") {
                Task { await model.simulate(.touchdown, mine: false) }
            }
            Button("Field goal (+3)") {
                Task { await model.simulate(.fieldGoal, mine: true) }
            }
            Button(model.isSimulating ? "Parar el partido simulado" : "Partido simulado (cada 12 s)") {
                if model.isSimulating {
                    model.stopFakeGame()
                } else {
                    model.startFakeGame()
                }
            }
            .foregroundStyle(model.isSimulating ? Color.orange : Theme.accent)
        } header: {
            Text("Pruebas")
        } footer: {
            Text("Suma puntos a un titular al azar y lo mete por el mismo camino que los datos reales: detección de anotación, Live Activity y notificación. La jugada tarda 2 segundos a propósito, para darte tiempo a cerrar la app y verla llegar. Mientras el partido simulado esté en marcha no se descargan los puntos de verdad.")
        }
        #endif
    }

    // MARK: - Resto de ajustes

    private var widgetSection: some View {
        Section {
            Label(
                SharedStore.usesAppGroup ? "Compartido con el widget" : "Widget sin datos compartidos",
                systemImage: SharedStore.usesAppGroup ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(SharedStore.usesAppGroup ? Theme.accent : .orange)
        } header: {
            Text("Widget")
        } footer: {
            Text(
                SharedStore.usesAppGroup
                ? "El widget usa la liga y el equipo que elijas aquí."
                : "Falta activar el grupo de apps (App Groups) en Xcode. Sin él, el widget se queda con la liga por defecto del código."
            )
        }
    }

    private var catalogSection: some View {
        Section {
            Button {
                isRefreshingCatalog = true
                Task {
                    await model.forceCatalogRefresh()
                    catalogDate = await PlayerCatalog.shared.savedAt
                    isRefreshingCatalog = false
                }
            } label: {
                if isRefreshingCatalog {
                    HStack { ProgressView(); Text("Descargando…") }
                } else {
                    Text("Actualizar catálogo de jugadores")
                }
            }
            .disabled(isRefreshingCatalog)
        } header: {
            Text("Nombres y fotos de los jugadores")
        } footer: {
            if let catalogDate {
                Text("Guardado el \(catalogDate.formatted(date: .abbreviated, time: .shortened)). Se renueva solo una vez al día.")
            } else {
                Text("Aún no se ha descargado. Son unos 5 MB y solo hace falta una vez al día.")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Versión", value: Bundle.main.shortVersion)
            Link("API de Sleeper", destination: URL(string: "https://docs.sleeper.com")!)
        }
    }
}

/// Una fila del menú: plataforma, estado y a qué invita.
struct HostRow: View {
    var host: HostKind
    var connection: HostConnection?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.symbol)
                .font(.system(size: 20))
                .foregroundStyle(host.isAvailable ? host.accent : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.title)
                    .foregroundStyle(.primary)
                Text(connection.map { "Conectado como \($0.accountName)" } ?? host.tagline)
                    .font(.caption)
                    .foregroundStyle(connection == nil ? Color.secondary : Theme.accent)
            }

            Spacer()

            if !host.isAvailable {
                Text("Próximamente")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
            } else if connection != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Yahoo

struct YahooLoginView: View {
    @ObservedObject var auth: YahooAuth
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var error: String?
    /// El código que Yahoo enseña en pantalla cuando la vuelta es `oob`.
    @State private var pastedCode = ""
    @State private var showPasteBox = false

    var body: some View {
        NavigationStack {
            Form {
                if auth.isConnected {
                    Section {
                        Label("Sesión iniciada", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.accent)
                        // Lo concedido, no lo pedido. Si aquí no sale nada de
                        // fantasy, ninguna petición de ligas va a funcionar por
                        // mucho que el login diga que todo fue bien.
                        LabeledContent("Permisos") {
                            Text(auth.token?.grantedScope ?? "sin especificar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Cerrar sesión", role: .destructive) {
                            auth.signOut()
                        }
                    } footer: {
                        Text("El token queda en el llavero compartido, para que el widget y el refresco en segundo plano también puedan pedir datos. Cierra esto y usa «Añadir una liga de Yahoo» para elegir liga y equipo.")
                    }
                } else {
                    Section {
                        TextField("Client ID", text: $auth.credentials.clientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Client Secret", text: $auth.credentials.clientSecret)
                        TextField("Redirect URI", text: $auth.credentials.redirectURI)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Scope (déjalo vacío)", text: Binding(
                            get: { auth.credentials.scope ?? "" },
                            set: { auth.credentials.scope = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    } header: {
                        Text("Tu app de Yahoo")
                    } footer: {
                        Text("Se sacan registrando una app en developer.yahoo.com. En «Redirect URI» pega exactamente la dirección que ya viene aquí: Yahoo solo admite direcciones https, y esa es una página que no hace más que devolverte a la app. El scope déjalo vacío: pedir «fspt-r» hace que Yahoo conteste «invalid scope», porque su formulario de alta ya no ofrece el permiso de Fantasy Sports; sin scope concede lo que tenga la app. El client id y el secreto no vienen en el código a propósito —un secreto metido en una app de iPhone lo puede extraer cualquiera— y se guardan en el llavero de este teléfono.")
                    }

                    Section {
                        Button {
                            Task { await connect() }
                        } label: {
                            if isWorking {
                                HStack { ProgressView(); Text("Abriendo Yahoo…") }
                            } else {
                                Text("Iniciar sesión con Yahoo")
                            }
                        }
                        .disabled(isWorking || !auth.credentials.isComplete)
                    }

                    // Plan B. El salto de la página de vuelta a la app lo puede
                    // bloquear el sistema, y entonces el código se queda en
                    // pantalla: esto es para pegarlo y no quedarse tirado.
                    Section {
                        DisclosureGroup("¿No volvió sola?", isExpanded: $showPasteBox) {
                            TextField("Pega aquí el código", text: $pastedCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Conectar con ese código") {
                                Task { await connectPasted() }
                            }
                            .disabled(isWorking || pastedCode.isEmpty)
                        }
                    } footer: {
                        Text("Si al autorizar te quedaste en la página web con un código a la vista, cópialo y pégalo aquí.")
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Yahoo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private func connect() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await auth.signIn()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connectPasted() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await auth.connect(pastedCode: pastedCode)
            pastedCode = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Avatar de red con hueco de reserva, para las listas de ajustes.
struct AsyncAvatar: View {
    var url: URL?
    var size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
