//  RAVisionApp.swift — SwiftUI app entry for the visionOS build.
//
//  An ImmersiveSpace can only be declared from a SwiftUI `App`, so on visionOS
//  the entry point is Swift.  It is scene plumbing only: the WindowGroup hosts
//  RetroArch's existing UIKit stack (RAVisionHost.m) and the ImmersiveSpace
//  declares the CompositorServices layer whose render loop lives in
//  RAImmersive.m.  All emulator, input and settings logic stays in C/ObjC.
//
//  The settings sheet follows ~/dev/q2repro-ios/SETTINGS-SPEC-FROM-VKQUAKE.md —
//  the program's reference 3D UX — row for row, including its ranges, defaults
//  and readout formats.  Lengths are stored in metres; the units toggle only
//  changes how they read.
//
//  The whole file is compiled out on iOS/tvOS, which keep RetroArch's own
//  main() and UIApplicationMain path byte for byte.

#if os(visionOS)

import SwiftUI
import CompositorServices
import AVFAudio
import UIKit

// MARK: - Shared state

@MainActor
final class RAVisionModel: ObservableObject {
    static let shared = RAVisionModel()
    @Published var immersive = false
    @Published var showSettings = false

    // Mirrors of the C-side values so the sliders have somewhere to live.
    // Every setter writes straight through — a drag moves the real screen.
    @Published var distance: Float = 3.6
    @Published var width: Float = 5.5
    @Published var height: Float = 3.1
    @Published var positionHeight: Float = 0.0
    @Published var stereoDepth: Float = 1.0
    @Published var dim: Float = 0.8
    @Published var feet: Bool = true

    func pull() {
        distance       = ra_vision_panel_distance()
        width          = ra_vision_panel_width()
        height         = ra_vision_panel_height()
        positionHeight = ra_vision_panel_position_height()
        stereoDepth    = ra_vision_panel_stereo_depth()
        dim            = ra_vision_panel_dim()
        feet           = ra_vision_panel_units_feet()
    }
}

/// `hands` in 3dsen.cfg, read at each 3D entry (default hidden).
/// Its own object so RAVisionApp.body re-evaluates only on this flag, not on
/// every settings-slider drag in RAVisionModel.
@MainActor
final class RAHandsModel: ObservableObject {
    static let shared = RAHandsModel()
    @Published var hidden = true
}

// MARK: - C bridges

@_cdecl("RA_SetImmersiveMode")
func RA_SetImmersiveMode(_ on: Bool) {
    Task { @MainActor in RAVisionModel.shared.immersive = on }
}

/// set by ra_vision_3d_begin (main thread) just before
/// RA_SetImmersiveMode(true), so the space opens with the right limb visibility.
@_cdecl("RA_SetHandsHidden")
func RA_SetHandsHidden(_ hidden: Bool) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { RAHandsModel.shared.hidden = hidden }
    } else {
        Task { @MainActor in RAHandsModel.shared.hidden = hidden }
    }
}

/// Validation hook (see RAVisionHost.m) — simctl cannot tap an ornament.
@_cdecl("RA_OpenSettingsSheet")
func RA_OpenSettingsSheet() {
    Task { @MainActor in RAVisionModel.shared.showSettings = true }
}

/// In 3D the sound should come from the screen you are looking at, not from the
/// control card parked off to one side.
@_cdecl("RA_SetAudioFrontStage")
func RA_SetAudioFrontStage(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        if on {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .medium, anchoringStrategy: .front))
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
    } catch {
        NSLog("[RA3D] setIntendedSpatialExperience(\(on)) failed: \(error)")
    }
}

// MARK: - Hosting

struct RAHostView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { RA_MakeHostViewController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

// MARK: - Compositor configuration

struct RACompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        // Eye-tracked foveation concentrates rasterization where the user is
        // looking — the same mechanism that keeps system windows crisp, and a
        // straight win here. Cost is zero-to-negative.
        let foveated = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        // TRAP: with the LAYERED layout the drawable carries ONE multi-layer
        // rate map and per-slice passes all rasterize with layer 0's — the right
        // eye becomes a head-coupled fisheye. Dedicated gives each eye its own
        // texture AND map, which the texture-map-driven loop targets correctly.
        if foveated && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
        // Never hardcode rgba16Float — negotiate from what the device offers.
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        // (dev only): RA3D_COLORFMT=rgba16Float forces the device's float
        // drawable in the simulator (which defaults to bgra8Unorm_srgb), so
        // out-of-range/NaN shader output is visible to the alpha dump.
        NSLog("[RA3D] compositor color formats offered: \(capabilities.supportedColorFormats.map { $0.rawValue })")
        if ProcessInfo.processInfo.environment["RA3D_COLORFMT"] == "rgba16Float",
           capabilities.supportedColorFormats.contains(.rgba16Float) {
            configuration.colorFormat = .rgba16Float
        }
        if ProcessInfo.processInfo.environment["RA3D_ALPHA_DUMP"] != nil {
            configuration.colorUsage = [.renderTarget, .shaderRead]
        }
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        // Do NOT touch maxRenderQuality: it aborts the process at immersive
        // entry with no non-aborting way to validate it first.
        NSLog("[RA3D] compositor configured (foveation=\(foveated) dedicated=\(configuration.layout == .dedicated))")
    }
}

// MARK: - Settings

@MainActor
private func lengthText(_ metres: Float, signed: Bool = false) -> String {
    let feet = RAVisionModel.shared.feet
    let v = feet ? metres * 3.28084 : metres
    let unit = feet ? "ft" : "m"
    return String(format: signed ? "%+.1f %@" : "%.1f %@", v, unit)
}

struct RASettingsView: View {
    @ObservedObject private var model = RAVisionModel.shared

    var body: some View {
        VStack(spacing: 0) {
            // Own header bar: a hosted nav-bar Done does not survive
            // presentation from the small parked window, and losing every
            // control but the window-close X kills the audio session.
            HStack {
                Text("Vision Pro 3D").font(.title3.weight(.semibold))
                Spacer()
                Button("Reset") {
                    ra_vision_panel_defaults()
                    pushAll()
                    model.pull()
                }
                .buttonStyle(.bordered)
                Button("Done") { model.showSettings = false }
                    .buttonStyle(.borderedProminent)
            }
            .font(.title3)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()

            Form {
                Section("Screen") {
                    row("Screen Distance", $model.distance, 1.0...8.0,
                        lengthText(model.distance)) { ra_vision_panel_set_distance($0) }
                    row("Screen Width", $model.width, 1.2...8.0,
                        lengthText(model.width)) { ra_vision_panel_set_width($0) }
                    row("Screen Height", $model.height, 1.0...6.0,
                        lengthText(model.height)) { ra_vision_panel_set_height($0) }
                    row("Screen Position Height", $model.positionHeight, -1.5...10.0,
                        lengthText(model.positionHeight, signed: true)) {
                        ra_vision_panel_set_position_height($0)
                    }
                }

                Section {
                    row("Stereo Depth", $model.stereoDepth, 0.0...3.2,
                        String(format: "%.0f%%", model.stereoDepth * 100)) {
                        ra_vision_panel_set_stereo_depth($0)
                    }
                } header: {
                    Text("Depth")
                } footer: {
                    Text("How far apart the picture's layers sit. The background stays on the "
                       + "screen you placed; sprites move toward you. 0% is a flat screen — "
                       + "identical to 2D. NES only for now; other systems show a flat screen.")
                }

                Section("Panel") {
                    LabeledContent("Panel Width")  { Text(renderSize.0).monospacedDigit() }
                    LabeledContent("Panel Height") { Text(renderSize.1).monospacedDigit() }
                    LabeledContent("Aspect Ratio") { Text(aspectText).monospacedDigit() }
                }

                Section("Room") {
                    row("Surroundings Dimming", $model.dim, 0.0...1.0,
                        String(format: "%.0f%%", model.dim * 100)) { ra_vision_panel_set_dim($0) }
                }

                Section {
                    Picker("Units", selection: $model.feet) {
                        Text("m").tag(false)
                        Text("ft").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.feet) { _, v in ra_vision_panel_set_units_feet(v) }

                    Button("Recenter Screen") { ra_vision_panel_recenter() }
                } footer: {
                    Text("Recenter puts the screen straight ahead of where you are looking now.")
                }
            }
            .formStyle(.grouped)
        }
        // Width-only frame: forcing a height taller than the sheet surface makes
        // SwiftUI centre-clip the content and eat the header bar.
        .frame(minWidth: 900)
        .onAppear { model.pull() }
    }

    private var renderSize: (String, String) {
        var w: UInt32 = 0, h: UInt32 = 0
        ra_vision_panel_render_size(&w, &h)
        return ("\(w) px", "\(h) px")
    }

    private var aspectText: String {
        var w: UInt32 = 0, h: UInt32 = 0
        ra_vision_panel_render_size(&w, &h)
        guard h > 0 else { return "—" }
        let a = Double(w) / Double(h)
        return String(format: "%.0f:9", (a * 9).rounded())
    }

    private func pushAll() {
        ra_vision_panel_set_distance(ra_vision_panel_distance())
    }

    @ViewBuilder
    private func row(_ title: String, _ value: Binding<Float>,
                     _ range: ClosedRange<Float>, _ readout: String,
                     _ apply: @escaping (Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(readout).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, v in apply(v) }
        }
    }
}

// MARK: - Root view

struct RARootView: View {
    @ObservedObject private var model = RAVisionModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    // Launch instrumentation: a dead launch must name the last milestone it
    // reached. Without these, an OTA-only failure logs "process spawned" and
    // then nothing at all — which is exactly what did.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RAHostView()
            .ignoresSafeArea()
            // Controls sit BELOW the window: contentAlignment .top anchors the
            // pill's top edge to the window's bottom so it can never overlap
            // game content the way a default centred ornament does.
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    Button(model.immersive ? "Exit 3D" : "3D") {
                        ra_vision_enter_3d(!model.immersive)
                    }
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3)
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)
            }
            // A UIKit modal silently fails to present over an open
            // ImmersiveSpace; a SwiftUI sheet presents alongside the screen.
            .sheet(isPresented: $model.showSettings) { RASettingsView() }
            // Scene-lifecycle URL delivery: retroarch:// links and "Open in
            // RetroArch" from Files arrive here, not at the app delegate.
            .onOpenURL { url in _ = RA_HandleOpenURL(url) }
            .onAppear {
                RA_BeaconMark("swift RARootView onAppear")
                // Arm the aspect lock as soon as there is a window. The
                // frontend arms it too (patch 0015) but only when it actually
                // issues a resize; this covers the launch that already matches.
                ra_vision_arm_aspect_lock()
            }
            .onChange(of: scenePhase) { _, phase in
                RA_BeaconMark("swift scenePhase=\(phase)")
                // A scene that has just become active may have been resized by
                // the system while backgrounded; re-arm rather than trust it.
                if phase == .active { ra_vision_arm_aspect_lock() }
            }
            .onChange(of: model.immersive) { _, on in
                Task {
                    if on {
                        let result = await openImmersiveSpace(id: "RA3D")
                        NSLog("[RA3D] openImmersiveSpace -> \(String(describing: result))")
                        if case .error = result {
                            // Roll back — the engine must never be left rendering
                            // offscreen with no compositor to show it.
                            ra_vision_enter_3d(false)
                            ra_vision_exit_3d_finalize()
                        }
                    } else {
                        await dismissImmersiveSpace()
                        ra_vision_exit_3d_finalize()
                    }
                }
            }
    }
}

// MARK: - App

@main
struct RAVisionApp: App {
    // RetroArch_iOS is both the UINavigationController and the
    // UIApplicationDelegate upstream; keeping it as the delegate means
    // [RetroArch_iOS get] keeps resolving and every frontend path that reaches
    // for the delegate works unchanged.  Its -applicationDidFinishLaunching is
    // deferred by overlay 0010 and run from the host view controller instead.
    @UIApplicationDelegateAdaptor(RetroArch_iOS.self) var appDelegate
    @ObservedObject private var hands = RAHandsModel.shared

    init() {
        RA_BeaconMark("swift app init")
    }

    var body: some Scene {
        WindowGroup {
            RARootView()
        }
        ImmersiveSpace(id: "RA3D") {
            CompositorLayer(configuration: RACompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread — running the frame loop
                // here would block RetroArch's runloop observer and freeze the
                // emulator. Dedicated thread, always.
                let thread = Thread { RA_Immersive_Run(layerRenderer) }
                thread.name = "RA-Immersive"
                thread.stackSize = 2 << 20
                thread.start()
            }
        }
        // Mixed only. Merely ALLOWING .progressive changes the drawable contract
        // and cp_drawable_encode_present aborts __BUG_IN_CLIENT__ — which is why
        // room dimming is drawn by hand in the render loop.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        // hide the passthrough hands/arms over the 3D scene unless
        // `hands = 1`. Scoped to this space; the 2D window never hides them.
        .upperLimbVisibility(hands.hidden ? .hidden : .visible)
    }
}

#endif  // os(visionOS)
