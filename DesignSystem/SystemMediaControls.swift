import SwiftUI
import MediaPlayer
import AVKit

/// Wraps `MPVolumeView` for its embedded system volume slider. This is the
/// *only* sanctioned way for an app to let someone adjust output volume —
/// there is no public API to bind a custom `Slider` to system volume
/// directly. Apple owns the slider's exact rendering; tint is the only real
/// styling lever.
struct SystemVolumeSlider: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = tint
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.tintColor = tint
    }
}

/// Wraps `AVRoutePickerView` — the system AirPlay/output-route button, same
/// one used in Control Center. Like the volume slider, this is the only
/// sanctioned way to expose route picking; Apple renders the glyph itself.
struct SystemRoutePickerButton: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.tintColor = tint
        view.activeTintColor = tint
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
    }
}
