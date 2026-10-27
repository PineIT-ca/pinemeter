import SwiftUI

struct BrokerLocalRoutesSection: View {
    @Bindable var appModel: AppModel
    var initialRows: [BrokerLocalRouteRow]? = nil
    @State private var rows: [BrokerLocalRouteRow] = []
    @State private var drafts: [BrokerLocalRoute] = []
    @State private var rejected: [UUID: [Field: String]] = [:]
    @State private var expanded: Set<UUID> = []
    @State private var manual: Set<UUID> = []

    private var routes: [BrokerLocalRoute] { appModel.settings.broker.policy.localRoutes }
    private var allRoutes: [BrokerLocalRoute] { routes + drafts }

    private struct ReloadKey: Equatable {
        let date: Date
        let routes: [BrokerLocalRoute]
        let enabled: Bool
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            card
                .task(id: ReloadKey(date: context.date, routes: routes, enabled: appModel.settings.broker.isEnabled)) {
                    if let initialRows { rows = initialRows }
                    else { rows = await appModel.brokerLocalRouteRows(now: context.date) }
                }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrokerSectionHeader(
                "Local and controlled routes", systemImage: "lock.shield",
                subtitle: "Models served on machines you run. Kept on this Mac only; profiles and routing updates never change them.",
                help: .localRoutes
            ) { addMenu }
            Text(appModel.settings.broker.isEnabled
                 ? "The broker checks each host's load in the background. A pick never waits for it."
                 : "The broker is off, so host load is not checked.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if allRoutes.isEmpty {
                BrokerEmptyState(title: "No local routes", systemImage: "cpu",
                    hint: "Add a model that T3 reaches on a machine you run, such as a llama.cpp server. The broker uses it only for the roles you tick.")
            } else {
                VStack(spacing: 8) {
                    ForEach(allRoutes, id: \.rowKey) { route in
                        routeRow(route, row: (initialRows ?? rows).first { $0.rowKey == route.rowKey })
                    }
                }
            }
            if let saveError = appModel.brokerLocalRouteSaveError {
                Label(saveError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }.brokerCard()
    }

    private func routeRow(_ route: BrokerLocalRoute, row: BrokerLocalRouteRow?) -> some View {
        let error = Self.validation(proposed(route), existing: allRoutes)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: binding(route.rowKey, \.enabled, fallback: false))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel("Use \(route.candidate)")
                    .disabled(error != nil).help(error == nil ? "" : "Complete the connection details to turn this route on.")
                if manual.contains(route.rowKey) {
                    TextField("t3:instance/model", text: fieldBinding(route.rowKey, .candidate))
                        .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption.monospaced()).frame(width: 260)
                        .accessibilityLabel("Candidate for \(route.candidate)")
                } else {
                    Text(route.candidate).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)
                }
                BrokerChip(text: route.host, tint: .secondary, isMonospaced: true).help("Host \(route.host)")
                Spacer(minLength: 8)
                if let state = row?.state, state != .brokerOff {
                    BrokerChip(text: state.rawValue, tint: .secondary).help(state.tooltip)
                }
                Menu {
                    Button("Remove Route", role: .destructive) {
                        remove(route.rowKey)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Actions for \(route.candidate)")
            }
            if error?.field == .candidate { validationText(error) }
            HStack(spacing: 8) {
                Text("Roles").font(.caption).foregroundStyle(.secondary)
                ForEach(BrokerLocalRoute.allowedRoles, id: \.self) { role in
                    Toggle(role, isOn: roleBinding(route.rowKey, role: role)).toggleStyle(.checkbox).font(.caption2)
                        .accessibilityLabel("\(role) for \(route.candidate)")
                }
                Spacer(minLength: 8)
                Text(row?.priceLevel.map { "Level \($0)" } ?? "—")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    .help("0 means free capacity now, 4 means the most expensive. Lower levels win when quality is equal. — means the broker cannot use this route now.")
                Group {
                    if let date = row?.observedAt { Text("Checked ") + Text(date, style: .relative) }
                    else { Text("Not checked") }
                }.font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: 86, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(get: { route.residency == .controlled }, set: { value in
                binding(route.rowKey, \.residency, fallback: nil).wrappedValue = value ? .controlled : nil
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Counts as controlled infrastructure").font(.caption)
                    Text("Turn on only for a host you run. A role with Controlled infrastructure only on picks only from routes marked controlled.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.checkbox).accessibilityLabel("\(route.candidate) counts as controlled infrastructure")
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(route.rowKey) || error != nil },
                set: { value in
                    if value { expanded.insert(route.rowKey) } else { expanded.remove(route.rowKey) }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    connectionField(route, field: .probeURL, label: "Probe address", placeholder: "http://host:11434", width: 220, error: error)
                    connectionField(route, field: .preset, label: "Model preset", placeholder: "model-name", width: 160, error: error)
                    connectionField(route, field: .host, label: "Host", placeholder: "", width: 140, error: error)
                    Text("Use the same address as T3's model provider, so the load Pinemeter reads is the host your work goes to. Pinemeter asks only for load, never sends prompts, and never loads a model.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } label: { Text("Connection").font(.caption).foregroundStyle(.secondary) }
        }.brokerInsetRow().accessibilityElement(children: .contain)
            .accessibilityLabel(Self.rowAccessibilityLabel(route: route, row: row))
    }

    static func rowAccessibilityLabel(route: BrokerLocalRoute, row: BrokerLocalRouteRow?) -> String {
        "\(route.candidate) on \(route.host), \(row?.state.rawValue ?? ""), price level \(row?.priceLevel.map(String.init) ?? "unavailable")"
    }

    private func connectionField(_ route: BrokerLocalRoute, field: Field, label: String,
                                 placeholder: String, width: CGFloat, error: Validation?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                TextField(placeholder, text: fieldBinding(route.rowKey, field))
                    .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption.monospaced()).frame(width: width)
                    .accessibilityLabel("\(label) for \(route.candidate)")
            }
            if error?.field == field { validationText(error) }
        }
    }

    private func validationText(_ error: Validation?) -> some View {
        Text(error?.message ?? "").font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }

    private var addMenu: some View {
        Menu {
            Section("Detected") {
                let detected = Self.detectedRoutes(appModel.discoveredT3Instances, existing: allRoutes)
                if detected.isEmpty { Text("No undeclared local models detected") }
                ForEach(detected, id: \.candidate) { item in
                    Button(item.label) { add(candidate: item.candidate, manualEntry: false) }
                }
            }
            Divider()
            Button("Manual Entry…") { add(candidate: "", manualEntry: true) }
        } label: { Label("Add Local Route", systemImage: "plus") }
            .menuStyle(.borderedButton).fixedSize().disabled(!Self.canAddRoute(count: allRoutes.count))
            .help("Up to 8 local routes.").accessibilityLabel("Add local route")
    }

    private func add(candidate: String, manualEntry: Bool) {
        guard Self.canAddRoute(count: allRoutes.count) else { return }
        let route = Self.newRoute(candidate: candidate)
        drafts.append(route)
        expanded.insert(route.rowKey)
        if manualEntry { manual.insert(route.rowKey) }
    }

    private func remove(_ key: UUID) {
        appModel.settings.broker.policy.localRoutes.removeAll { $0.rowKey == key }
        drafts.removeAll { $0.rowKey == key }
        rejected[key] = nil; expanded.remove(key); manual.remove(key)
    }

    private func binding<Value>(_ key: UUID, _ path: WritableKeyPath<BrokerLocalRoute, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { allRoutes.first { $0.rowKey == key }?[keyPath: path] ?? fallback }, set: { value in
            guard var route = allRoutes.first(where: { $0.rowKey == key }) else { return }
            route[keyPath: path] = value
            write(route)
        })
    }

    private func write(_ route: BrokerLocalRoute) {
        if let index = routes.firstIndex(where: { $0.rowKey == route.rowKey }) {
            appModel.settings.broker.policy.localRoutes[index] = route
        } else if let index = drafts.firstIndex(where: { $0.rowKey == route.rowKey }) {
            if Self.validation(route, existing: allRoutes) == nil {
                drafts.remove(at: index)
                appModel.settings.broker.policy.localRoutes.append(route)
            } else { drafts[index] = route }
        }
    }

    private func proposed(_ route: BrokerLocalRoute) -> BrokerLocalRoute {
        var proposed = route
        for (field, value) in rejected[route.rowKey] ?? [:] { proposed[keyPath: field.path] = value }
        return proposed
    }

    private func fieldBinding(_ key: UUID, _ field: Field) -> Binding<String> {
        Binding(get: {
            rejected[key]?[field] ?? allRoutes.first { $0.rowKey == key }?[keyPath: field.path] ?? ""
        }, set: { value in
            guard var route = allRoutes.first(where: { $0.rowKey == key }) else { return }
            if Self.setField(field, value: value, route: &route, existing: allRoutes) == nil {
                if field == .candidate && drafts.contains(where: { $0.rowKey == key }) {
                    let defaults = Self.newRoute(candidate: value)
                    if route.host.isEmpty { route.host = defaults.host }
                    if route.preset.isEmpty { route.preset = defaults.preset }
                }
                rejected[key]?[field] = nil
                write(route)
            } else { rejected[key, default: [:]][field] = value }
        })
    }

    private func roleBinding(_ key: UUID, role: String) -> Binding<Bool> {
        let value = binding(key, \.roles, fallback: [])
        return Binding(get: { value.wrappedValue.contains(role) }, set: { enabled in
            value.wrappedValue = BrokerLocalRoute.allowedRoles.filter {
                $0 == role ? enabled : value.wrappedValue.contains($0)
            }
        })
    }

    enum Field: String, CaseIterable {
        case candidate, host, probeURL, preset
        var path: WritableKeyPath<BrokerLocalRoute, String> {
            switch self {
            case .candidate: \.candidate
            case .host: \.host
            case .probeURL: \.probeURL
            case .preset: \.preset
            }
        }
    }
    struct Validation: Equatable { let field: Field; let message: String }

    static func validation(_ route: BrokerLocalRoute, existing: [BrokerLocalRoute]) -> Validation? {
        for field in Field.allCases {
            if let error = fieldError(field, route: route, existing: existing) { return .init(field: field, message: error) }
        }
        return nil
    }

    static func setField(_ field: Field, value: String, route: inout BrokerLocalRoute, existing: [BrokerLocalRoute]) -> String? {
        var proposed = route; proposed[keyPath: field.path] = value
        if let error = fieldError(field, route: proposed, existing: existing) { return error }
        if validation(route, existing: existing) == nil,
           let error = validation(proposed, existing: existing) { return error.message }
        route = proposed
        return nil
    }

    private static func fieldError(_ field: Field, route: BrokerLocalRoute, existing: [BrokerLocalRoute]) -> String? {
        let others = existing.filter { $0.rowKey != route.rowKey }
        switch field {
        case .candidate:
            guard let candidate = BrokerCandidate(id: route.candidate), candidate.route == .t3,
                  let instance = candidate.instance, T3InstanceConfig.isValidId(instance),
                  T3InstanceConfig.isValidModelSlug(candidate.model) else {
                return "Use t3:instance/model, for example t3:pi/lab/qwen-27b."
            }
            if candidate.model == "default" { return "Use an explicit model. default can point to any provider, including a cloud one." }
            if others.contains(where: { $0.candidate == route.candidate }) { return "This route is already declared." }
        case .host:
            guard T3InstanceConfig.isValidIdentifier(route.host, maxLength: 64) else { return "Use letters, digits, dots, dashes or underscores." }
            if Set((others + [route]).map(\.host).filter { !$0.isEmpty }).count > BrokerLocalRoute.maxHosts { return "Up to 4 hosts." }
        case .probeURL:
            let canonical = { (s: String) in s.hasSuffix("/") ? String(s.dropLast()) : s }
            if !BrokerLocalRoute.isValidProbeURL(route.probeURL)
                || others.contains(where: { $0.host == route.host && canonical($0.probeURL) != canonical(route.probeURL) }) {
                return "Use http:// or https:// with a host and port only."
            }
        case .preset:
            if !T3InstanceConfig.isValidIdentifier(route.preset.replacingOccurrences(of: ":", with: "_"), maxLength: 128) {
                return "Enter the model name the host's server uses."
            }
        }
        return nil
    }

    struct DetectedRoute { let candidate: String; let label: String }
    static func canAddRoute(count: Int) -> Bool { count < BrokerLocalRoute.maxRoutes }
    static func detectedRoutes(_ instances: [DiscoveredT3Instance], existing: [BrokerLocalRoute]) -> [DetectedRoute] {
        var seen = Set(existing.map(\.candidate))
        return instances.flatMap { instance in
            instance.modelSlugs.compactMap { slug -> DetectedRoute? in
                let candidate = "t3:\(instance.instanceId)/\(slug)"
                guard slug.contains("/"), slug != "default", T3InstanceConfig.isValidModelSlug(slug),
                      T3InstanceConfig.isValidId(instance.instanceId), seen.insert(candidate).inserted else { return nil }
                return .init(candidate: candidate, label: "\(instance.displayName ?? instance.instanceId): \(slug)")
            }
        }
    }

    static func newRoute(candidate: String) -> BrokerLocalRoute {
        let parts = BrokerCandidate(id: candidate)?.model.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        let host = parts.first.flatMap { T3InstanceConfig.isValidIdentifier($0, maxLength: 64) ? $0 : nil } ?? ""
        let preset = parts.count == 2 && T3InstanceConfig.isValidIdentifier(parts[1].replacingOccurrences(of: ":", with: "_"), maxLength: 128) ? parts[1] : ""
        return .init(candidate: candidate, host: host, probeURL: "", preset: preset, enabled: false, roles: ["explore", "verification"])
    }
}
