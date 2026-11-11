// 작은 말소리 키우기: 데스크톱 ffmpeg `dynaudnorm=f=500:g=31:p=0.9:m=50`와 같은 방식.
// whisper(특히 VAD)는 작게 말한 구간을 말소리가 아닌 것으로 보고 건너뛴다.
// 0.5초 조각마다 최대 진폭을 p까지 올리는 배율(최대 m배)을 구하고,
// 앞뒤 g조각에서 가장 작은 배율 → 가우스 평균으로 부드럽게 이어 붙인다
// (큰 소리 바로 옆이 갑자기 커지지 않게).
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace transcue {

inline void normalizeLoudness(float *pcm, size_t n, int sampleRate = 16000,
                              double frameMs = 500, int window = 31,
                              double peak = 0.9, double maxGain = 50) {
  const size_t frame = static_cast<size_t>(sampleRate * frameMs / 1000);
  if (frame == 0 || n == 0) return;
  const size_t nf = (n + frame - 1) / frame;
  const int half = window / 2;

  std::vector<double> gain(nf);
  for (size_t f = 0; f < nf; f++) {
    float mx = 0;
    for (size_t i = f * frame, e = std::min(n, i + frame); i < e; i++) {
      mx = std::max(mx, std::fabs(pcm[i]));
    }
    gain[f] = mx > 0 ? std::min(peak / mx, maxGain) : maxGain;
  }

  auto at = [&](const std::vector<double> &v, long i) {
    return v[static_cast<size_t>(std::clamp(i, 0L, static_cast<long>(nf) - 1))];
  };
  std::vector<double> lo(nf);
  for (size_t f = 0; f < nf; f++) {
    double m = gain[f];
    for (long k = -half; k <= half; k++) m = std::min(m, at(gain, f + k));
    lo[f] = m;
  }
  const double sigma = half / 3.0 > 0 ? half / 3.0 : 1;
  std::vector<double> smooth(nf);
  for (size_t f = 0; f < nf; f++) {
    double s = 0, w = 0;
    for (long k = -half; k <= half; k++) {
      const double wk = std::exp(-0.5 * k * k / (sigma * sigma));
      s += wk * at(lo, f + k);
      w += wk;
    }
    smooth[f] = s / w;
  }

  // 조각 가운데끼리 배율을 직선으로 이어 경계에서 소리가 튀지 않게 한다
  for (size_t i = 0; i < n; i++) {
    const double pos = (static_cast<double>(i) + 0.5) / frame - 0.5;
    const long f0 = static_cast<long>(std::floor(pos));
    const double t = pos - f0;
    const double g = at(smooth, f0) * (1 - t) + at(smooth, f0 + 1) * t;
    pcm[i] = static_cast<float>(std::clamp(pcm[i] * g, -1.0, 1.0));
  }
}

}  // namespace transcue
