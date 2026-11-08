use serde::{Deserialize, Serialize};

/// 원문과 번역문을 함께 가진 자막 한 줄. 시간 단위는 밀리초.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BilingualCue {
    pub id: u32,
    pub start_ms: u64,
    pub end_ms: u64,
    pub original: String,
    pub translation: Option<String>,
}

/// `t_ms` 시점에 표시할 큐를 이진 탐색으로 찾는다. (`cues`는 start 기준 정렬)
pub fn cue_at(cues: &[BilingualCue], t_ms: u64) -> Option<&BilingualCue> {
    let idx = cues.partition_point(|c| c.start_ms <= t_ms);
    let c = cues.get(idx.checked_sub(1)?)?;
    (t_ms < c.end_ms).then_some(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cue(id: u32, s: u64, e: u64) -> BilingualCue {
        BilingualCue {
            id,
            start_ms: s,
            end_ms: e,
            original: id.to_string(),
            translation: None,
        }
    }

    #[test]
    fn finds_active_cue() {
        let cues = [cue(1, 1000, 3000), cue(2, 3000, 6000), cue(3, 8000, 9000)];
        assert_eq!(cue_at(&cues, 500), None);
        assert_eq!(cue_at(&cues, 1000).map(|c| c.id), Some(1));
        assert_eq!(cue_at(&cues, 3000).map(|c| c.id), Some(2));
        assert_eq!(cue_at(&cues, 7000), None);
        assert_eq!(cue_at(&cues, 9000), None);
    }
}
