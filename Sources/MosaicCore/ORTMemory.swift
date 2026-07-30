@preconcurrency import OnnxRuntimeBindings
import Foundation

/// ONNX Runtime のメモリアリーナ運用。
///
/// ORTは推論用のバッファをアリーナ（プール）に確保し、**既定では推論が終わっても
/// OSへ返さない**。同じセッションで推論を繰り返すほど常駐量が増え続ける。
/// 実測（`MemoryFootprintTests`）:
///
///     SAM 読込のみ    +93 MB
///     SAM 推論1回目  +547 MB
///     SAM 推論2回目  +287 MB   ← 解放されずに積み上がる
///
/// これが「使用メモリが6GBを超える」報告の主因。`memory.enable_memory_arena_shrinkage`
/// を実行時オプションに与えると、ORTは各推論の完了時にアリーナを縮小してメモリを返す。
///
/// 代償は、次の推論でバッファを確保し直す分の時間。モザイク処理は1画像あたり数百ms〜数秒の
/// 処理であり、確保のやり直しは相対的に小さい。常駐量が数GB積み上がる方が体感を悪くする。
public enum ORTMemory {
    /// 推論のたびにCPUアリーナを縮小する実行時オプション。
    /// 値の書式は `<デバイス>:<アリーナ番号>`。CPUのみ使うため `cpu:0`。
    ///
    /// 生成に失敗した場合は `nil` を返し、呼び出し側は従来どおり縮小なしで実行する
    /// （メモリは増えるが動作はする）。
    public static let shrinkingRunOptions: ORTRunOptions? = {
        do {
            let options = try ORTRunOptions()
            try options.addConfigEntry(
                withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0"
            )
            return options
        } catch {
            return nil
        }
    }()
}
