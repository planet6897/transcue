//! 번역 공급자 추상화.
//!
//! 자막은 줄 단위로 끊어 번역하면 문맥이 깨지므로, 큐를 묶음(batch)으로 보내고
//! 앞 묶음의 일부를 문맥으로 함께 전달한다. 응답은 `{id, text}` JSON 배열로 받아
//! 큐 ID로 다시 매칭한다. 실제 HTTP 호출은 M3에서 각 공급자별로 구현한다.

use serde::{Deserialize, Serialize};

use crate::cue::BilingualCue;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Provider {
    Claude,
    OpenAi,
    Gemini,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslateRequest {
    pub source_lang: String,
    pub target_lang: String,
    /// 문맥용(번역하지 않음) 직전 큐들
    pub context: Vec<SegmentIn>,
    /// 번역 대상
    pub segments: Vec<SegmentIn>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SegmentIn {
    pub id: u32,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SegmentOut {
    pub id: u32,
    pub text: String,
}

#[derive(Debug, thiserror::Error)]
pub enum TranslateError {
    #[error("API 오류: {0}")]
    Api(String),
    #[error("응답 형식 오류: {0}")]
    BadResponse(String),
}

/// 각 공급자(Claude/OpenAI/Gemini)가 구현할 인터페이스.
pub trait Translator: Send + Sync {
    fn provider(&self) -> Provider;
    fn translate(&self, req: &TranslateRequest) -> Result<Vec<SegmentOut>, TranslateError>;
}

/// 큐 목록을 번역 요청 묶음으로 나눈다.
pub fn make_batches(
    cues: &[BilingualCue],
    batch_size: usize,
    context_size: usize,
    source_lang: &str,
    target_lang: &str,
) -> Vec<TranslateRequest> {
    let seg = |c: &BilingualCue| SegmentIn {
        id: c.id,
        text: c.original.clone(),
    };
    let batch_size = batch_size.max(1);
    (0..cues.len())
        .step_by(batch_size)
        .map(|start| TranslateRequest {
            source_lang: source_lang.into(),
            target_lang: target_lang.into(),
            context: cues[start.saturating_sub(context_size)..start]
                .iter()
                .map(seg)
                .collect(),
            segments: cues[start..(start + batch_size).min(cues.len())]
                .iter()
                .map(seg)
                .collect(),
        })
        .collect()
}

/// 번역 결과를 큐에 반영한다. 반환값: 번역이 누락된 큐 ID (재시도 대상).
pub fn apply(cues: &mut [BilingualCue], req: &TranslateRequest, out: &[SegmentOut]) -> Vec<u32> {
    let mut missing = Vec::new();
    for s in &req.segments {
        match out.iter().find(|o| o.id == s.id) {
            Some(o) => {
                if let Some(c) = cues.iter_mut().find(|c| c.id == s.id) {
                    c.translation = Some(o.text.clone());
                }
            }
            None => missing.push(s.id),
        }
    }
    missing
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cues(n: u32) -> Vec<BilingualCue> {
        (1..=n)
            .map(|i| BilingualCue {
                id: i,
                start_ms: i as u64,
                end_ms: i as u64 + 1,
                original: format!("s{i}"),
                translation: None,
            })
            .collect()
    }

    #[test]
    fn batches_with_context() {
        let b = make_batches(&cues(5), 2, 1, "en", "ko");
        assert_eq!(b.len(), 3);
        assert!(b[0].context.is_empty());
        assert_eq!(
            b[1].context.iter().map(|s| s.id).collect::<Vec<_>>(),
            vec![2]
        );
        assert_eq!(
            b[2].segments.iter().map(|s| s.id).collect::<Vec<_>>(),
            vec![5]
        );
    }

    #[test]
    fn apply_reports_missing() {
        let mut cs = cues(3);
        let req = &make_batches(&cs, 3, 0, "en", "ko")[0];
        let out = vec![
            SegmentOut {
                id: 1,
                text: "일".into(),
            },
            SegmentOut {
                id: 3,
                text: "삼".into(),
            },
        ];
        assert_eq!(apply(&mut cs, req, &out), vec![2]);
        assert_eq!(cs[0].translation.as_deref(), Some("일"));
        assert_eq!(cs[1].translation, None);
    }
}
