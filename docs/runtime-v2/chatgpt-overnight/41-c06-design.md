[[PARTE 2/3]]

C-06 — desenho: o cancelamento pertence ao waiter, não à Task single-flight. Portanto o helper precisa liberar o chamador cancelado imediatamente, enquanto a resolução compartilhada continua para os demais.

Em MediaAssetStore.swift, substituir a âncora:

if let task = inFlight[key] {
    return try? await task.value
}

por:

if let task = inFlight[key] {
    return try? await awaitSharedTaskRespectingCancellation(task)
}
e usar o mesmo helper no primeiro chamador.

private final class SharedWait<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func complete(_ value: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: value)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let result {
                lock.unlock()
                c.resume(with: result)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

func awaitSharedTaskRespectingCancellation<T: Sendable>(
    _ shared: Task<T, Error>
) async throws -> T {
    let wait = SharedWait<T>()

    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        Task {
            do { wait.complete(.success(try await shared.value)) }
            catch { wait.complete(.failure(error)) }
        }
        return try await wait.value()
    } onCancel: {
        wait.complete(.failure(CancellationError()))
    }
}
Importante: mover também o inFlight[key] = nil para um monitor da conclusão da shared task. O waiter criador pode agora cancelar cedo; ele não pode remover a chave enquanto a resolução continua.

Teste:
testCancelledWaiterReturnsImmediatelyWithoutCancellingSharedResolution()

Criar uma shared task bloqueada por gate; dois waiters aguardam a mesma task. Cancelar A e exigir que termine com CancellationError antes de abrir o gate. Depois abrir o gate e provar que B recebe o resultado e shared.isCancelled == false.

NÃO fazer:

onCancel: { shared.cancel() }
Isso cancela a resol