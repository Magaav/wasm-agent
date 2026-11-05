# Native baseline: the same model.onnx and input through onnxruntime directly.
# python native.py <model-dir> <iterations>
import sys, time, numpy as np, onnxruntime as ort
d, n = sys.argv[1], int(sys.argv[2])
t = time.time(); s = ort.InferenceSession(d + "/model.onnx", providers=["CPUExecutionProvider"]); print(f"native: session in {(time.time()-t)*1000:.0f} ms (onnxruntime {ort.__version__})")
x = np.zeros((1, 80, 3000), dtype=np.float32)
out = None; times = []
for i in range(n + 1):
    t = time.time(); out = s.run(None, {"input_features": x}); ms = (time.time() - t) * 1000
    if i == 0: print(f"native: warmup {ms:.0f} ms -> {out[0].shape}")
    else: times.append(ms)
times.sort(); print(f"native: median {times[len(times)//2]:.0f} ms over {n} runs (min {times[0]:.0f}, max {times[-1]:.0f})")
