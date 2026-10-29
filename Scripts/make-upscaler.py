# Builds Resources/Upscaler.mlpackage: Real-ESRGAN "realesr-animevideov3" (SRVGGNetCompact, 4×, BSD-3,
# https://github.com/xinntao/Real-ESRGAN) as a Core ML image→image model, fp16, any size up to 4096 px.
# Usage: python Scripts/make-upscaler.py realesr-animevideov3.pth   (needs torch + coremltools)
import sys, torch, torch.nn as nn, torch.nn.functional as F, coremltools as ct

class SRVGGNetCompact(nn.Module):  # architecture from Real-ESRGAN
    def __init__(self, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList([nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_feat)])
        for _ in range(num_conv):
            self.body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_feat)]
        self.body.append(nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out) + F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return (out.clamp(0, 1) * 255)  # image output expects 0…255

net = SRVGGNetCompact()
state = torch.load(sys.argv[1], map_location="cpu", weights_only=True)
net.load_state_dict(state.get("params", state))
net.eval()
size = (1, 3, ct.RangeDim(16, 4096, default=64), ct.RangeDim(16, 4096, default=64))
model = ct.convert(torch.jit.trace(net, torch.rand(1, 3, 64, 64)),
                   inputs=[ct.ImageType(name="input", shape=ct.Shape(size), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
                   outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
                   compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
model.short_description = "Real-ESRGAN animevideov3 4× upscaler (BSD-3, xinntao/Real-ESRGAN)"
model.save("Resources/Upscaler.mlpackage")
print("Wrote Resources/Upscaler.mlpackage")
