import SwiftUI
import UIKit

/// Seleção de vários itens arrastando o dedo, como no app Fotos: no modo de seleção, encoste num
/// cartão (ou página) e deslize para o lado; continuando para cima ou para baixo, todos os itens
/// entre o primeiro e o atual, na ordem da grade, mudam juntos. Começando num item marcado, o
/// arraste desmarca. Perto da borda de cima ou de baixo, a tela rola sozinha. Um movimento que
/// começa na vertical continua rolando a tela normalmente.
enum DragSelect {
    static let space = "prumo.dragselect"
}

struct DragSelectFramesKey: PreferenceKey {
    static let defaultValue: [AnyHashable: CGRect] = [:]
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Informa onde está um item, para a seleção arrastando o dedo.
    func dragSelectItem<ID: Hashable>(_ id: ID) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: DragSelectFramesKey.self,
                                   value: [AnyHashable(id): g.frame(in: .named(DragSelect.space))])
        })
    }

    /// Liga a seleção arrastando o dedo na grade (só quando `enabled`).
    func dragSelect<ID: Hashable>(enabled: Bool, order: [ID], isSelected: @escaping (ID) -> Bool,
                                  set: @escaping (ID, Bool) -> Void) -> some View {
        modifier(DragSelectModifier(enabled: enabled, order: order, isSelected: isSelected, set: set))
    }
}

struct DragSelectModifier<ID: Hashable>: ViewModifier {
    let enabled: Bool
    let order: [ID]
    let isSelected: (ID) -> Bool
    let set: (ID, Bool) -> Void
    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var start: Int?
    @State private var mode = true
    @State private var original: [Int: Bool] = [:]

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: DragSelect.space)
            .onPreferenceChange(DragSelectFramesKey.self) { frames = $0 }
            .background(DragSelectProbe(enabled: enabled,
                                        canBegin: { index(at: $0) != nil },
                                        onBegan: began,
                                        onChanged: changed,
                                        onEnded: ended))
    }

    private func index(at p: CGPoint) -> Int? {
        order.firstIndex { frames[AnyHashable($0)]?.contains(p) == true }
    }

    private func began(_ p: CGPoint) {
        guard let i = index(at: p) else { return }
        start = i
        mode = !isSelected(order[i])
        original = [:]
        apply(to: i)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func changed(_ p: CGPoint) {
        guard start != nil, let i = index(at: p) else { return }   // entre dois cartões: fica como está
        apply(to: i)
    }

    private func ended() {
        start = nil
        original = [:]
    }

    private func apply(to current: Int) {
        guard let s = start else { return }
        let range = min(s, current)...max(s, current)
        var orig = original
        // Itens que saíram do intervalo voltam ao que eram antes do arraste.
        for (k, was) in orig where !range.contains(k) {
            if order.indices.contains(k), isSelected(order[k]) != was { set(order[k], was) }
            orig[k] = nil
        }
        for k in range where order.indices.contains(k) {
            if orig[k] == nil { orig[k] = isSelected(order[k]) }
            if isSelected(order[k]) != mode { set(order[k], mode) }
        }
        original = orig
    }
}

/// Liga um reconhecedor de arraste (do UIKit) à rolagem da tela. Ele só começa num movimento
/// horizontal sobre um item; na vertical, desiste na hora e a tela rola.
struct DragSelectProbe: UIViewRepresentable {
    var enabled: Bool
    var canBegin: (CGPoint) -> Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setEnabled(enabled)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.setEnabled(false)
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { coordinator?.attach(from: self) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DragSelectProbe
        weak var probe: UIView?
        weak var scrollView: UIScrollView?
        private var enabled = false
        private var link: CADisplayLink?
        private lazy var pan: UIPanGestureRecognizer = {
            let p = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            p.maximumNumberOfTouches = 1
            p.delegate = self
            return p
        }()

        init(_ parent: DragSelectProbe) { self.parent = parent }

        func attach(from view: UIView) {
            probe = view
            var s = view.superview
            while let v = s, !(v is UIScrollView) { s = v.superview }
            scrollView = s as? UIScrollView
            install()
        }

        func setEnabled(_ on: Bool) {
            guard on != enabled else { return }
            enabled = on
            install()
        }

        private func install() {
            if enabled {
                guard pan.view == nil, let host = scrollView ?? probe?.superview else { return }
                host.addGestureRecognizer(pan)
                // A rolagem espera este arraste decidir (desiste logo se o movimento for vertical).
                scrollView?.panGestureRecognizer.require(toFail: pan)
            } else {
                stopLink()
                pan.view?.removeGestureRecognizer(pan)
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan, let probe else { return true }
            let v = pan.velocity(in: probe)
            guard abs(v.x) > abs(v.y) else { return false }
            let t = pan.translation(in: probe)
            let p = pan.location(in: probe)
            return parent.canBegin(CGPoint(x: p.x - t.x, y: p.y - t.y))
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            guard let probe else { return }
            switch g.state {
            case .began:
                let t = g.translation(in: probe)
                let p = g.location(in: probe)
                parent.onBegan(CGPoint(x: p.x - t.x, y: p.y - t.y))
                parent.onChanged(p)
                startLink()
            case .changed:
                parent.onChanged(g.location(in: probe))
            default:
                stopLink()
                parent.onEnded()
            }
        }

        // MARK: rolagem automática perto das bordas
        private func startLink() {
            stopLink()
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }

        private func stopLink() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            guard let sv = scrollView, let probe, pan.state == .began || pan.state == .changed else { return }
            let y = pan.location(in: sv).y - sv.bounds.minY
            let h = sv.bounds.height
            let edge: CGFloat = 70
            var speed: CGFloat = 0
            if y < edge { speed = -14 * min(1, (edge - y) / edge) }
            if y > h - edge { speed = 14 * min(1, (y - (h - edge)) / edge) }
            guard speed != 0 else { return }
            let minY = -sv.adjustedContentInset.top
            let maxY = max(minY, sv.contentSize.height - h + sv.adjustedContentInset.bottom)
            let newY = min(maxY, max(minY, sv.contentOffset.y + speed))
            guard newY != sv.contentOffset.y else { return }
            sv.contentOffset.y = newY
            parent.onChanged(pan.location(in: probe))
        }
    }
}
