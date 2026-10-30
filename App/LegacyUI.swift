import SwiftUI

private struct LegacyChange<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    @State private var appeared = false
    let action: (Value, Value) -> Void
    @State private var previous: Value
    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value; self.initial = initial; self.action = action
        _previous = State(initialValue: value)
    }
    func body(content: Content) -> some View {
        content.onAppear { if !appeared { appeared = true; if initial { action(value, value) } } }
            .onChange(of: value) { next in let old = previous; previous = next; action(old, next) }
    }
}
extension View {
    func legacyOnChange<Value: Equatable>(of value: Value, initial: Bool = false, perform action: @escaping (Value, Value) -> Void) -> some View {
        modifier(LegacyChange(value: value, initial: initial, action: action))
    }
    func legacyOnChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        onChange(of: value, perform: action)
    }
}
