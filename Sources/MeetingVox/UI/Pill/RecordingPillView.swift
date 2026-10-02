import SwiftUI

/// The pill's four faces over one `PillViewModel`. Buttons call the model's
/// closures; none has a keyboard shortcut (the panel is never key anyway), so
/// recording and stopping always need a deliberate click.
struct RecordingPillView: View {
    let model: PillViewModel

    var body: some View {
        Group {
            switch model.face {
            case .hidden:
                EmptyView()
            case .detected(let label):
                DetectedFace(model: model, label: label)
            case .recording:
                RecordingFace(model: model, silentMic: false)
            case .silentMic:
                RecordingFace(model: model, silentMic: true)
            case .ended(let title):
                EndedFace(model: model, title: title)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(width: RecordingPillPanel.width)
    }
}

private struct TemplatePicker: View {
    let model: PillViewModel

    var body: some View {
        if let templates = model.templates, !templates.isEmpty {
            Picker(
                Textos.Reuniones.plantilla,
                selection: Binding(get: { model.selection }, set: { model.select($0) })
            ) {
                ForEach(templates, id: \.id) { template in
                    Text(template.nombre).tag(String?.some(template.id))
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private struct DetectedFace: View {
    let model: PillViewModel
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Textos.Reuniones.detectada(label)).font(.headline)
                    Text(Textos.Reuniones.pregunta).font(.callout).foregroundStyle(.secondary)
                }
            }
            TemplatePicker(model: model)
            HStack {
                Spacer()
                Button(Textos.Reuniones.ignorar) { model.onIgnore() }
                Button(Textos.Reuniones.grabar) { model.onRecord(model.selection) }
            }
        }
    }
}

private struct RecordingFace: View {
    let model: PillViewModel
    let silentMic: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill").font(.caption).foregroundStyle(.red)
                Text(Textos.Pildora.grabando).font(.headline)
                Text(model.elapsed)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.onHide() } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.borderless)
                    .help(Textos.Pildora.ocultar)
            }
            VStack(alignment: .leading, spacing: 4) {
                LevelMeterView(label: Textos.Pildora.yo, display: model.mic)
                LevelMeterView(label: Textos.Pildora.otros, display: model.system)
            }
            if silentMic {
                VStack(alignment: .leading, spacing: 6) {
                    Label(Textos.Pildora.micSilenciado, systemImage: "mic.slash.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Textos.Pildora.cambiarMicrofono) { model.onChangeMic() }
                }
            }
            TemplatePicker(model: model)
            HStack {
                Spacer()
                Button(Textos.Reuniones.detener) { model.onStop() }
            }
        }
    }
}

private struct EndedFace: View {
    let model: PillViewModel
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(Textos.Reuniones.preguntaDetener).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let countdown = model.countdown {
                Text(Textos.Pildora.seDetieneSola(countdown))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(Textos.Reuniones.seguirGrabando) { model.onContinue() }
                Button(Textos.Reuniones.detener) { model.onStop() }
            }
        }
    }
}
