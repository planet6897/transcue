//! DualCue 코어 라이브러리.
//!
//! - `cue`: 이중 언어 자막 모델
//! - `srt`: SRT 파싱/직렬화 (원문/번역/이중 자막 내보내기)
//! - `translate`: 번역 공급자 추상화 (Claude / OpenAI / Gemini)
//!
//! STT(whisper-rs), 오디오 추출(ffmpeg), 캐시(SQLite)는 M2에서 추가된다.

pub mod cue;
pub mod srt;
pub mod translate;
