import MLX

/// Runs one tiny computation on the GPU. It fails if MLX can't find its Metal shaders
/// (`default.metallib` in `mlx-swift_Cmlx.bundle`), which is what goes wrong in a badly built app.
public enum GPUCheck {
    public static func run() -> Float {
        let a = MLXArray([1, 2, 3, 4] as [Float])
        return (a * a).sum().item(Float.self)
    }
}
