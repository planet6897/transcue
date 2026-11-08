use crate::cue::BilingualCue;

#[derive(Debug, thiserror::Error)]
pub enum SrtError {
    #[error("잘못된 타임코드 (블록 {block}): {line}")]
    BadTimecode { block: usize, line: String },
}

fn parse_ts(s: &str) -> Option<u64> {
    // HH:MM:SS,mmm (점 구분도 허용)
    let s = s.trim().replace('.', ",");
    let (hms, ms) = s.split_once(',')?;
    let mut it = hms.split(':').map(|p| p.parse::<u64>().ok());
    let (h, m, sec) = (it.next()??, it.next()??, it.next()??);
    Some(((h * 60 + m) * 60 + sec) * 1000 + ms.parse::<u64>().ok()?)
}

fn fmt_ts(ms: u64) -> String {
    format!(
        "{:02}:{:02}:{:02},{:03}",
        ms / 3_600_000,
        ms / 60_000 % 60,
        ms / 1000 % 60,
        ms % 1000
    )
}

/// SRT 텍스트를 큐 목록으로 파싱한다. 원문만 채워진다.
pub fn parse(input: &str) -> Result<Vec<BilingualCue>, SrtError> {
    let normalized = input.trim_start_matches('\u{feff}').replace("\r\n", "\n");
    let mut cues = Vec::new();
    for (i, block) in normalized
        .split("\n\n")
        .filter(|b| !b.trim().is_empty())
        .enumerate()
    {
        let mut lines = block.lines().skip_while(|l| l.trim().is_empty());
        let first = lines.next().unwrap_or_default();
        // 번호 줄은 선택적
        let time_line = if first.contains("-->") {
            first
        } else {
            lines.next().unwrap_or_default()
        };
        let bad = || SrtError::BadTimecode {
            block: i + 1,
            line: time_line.to_string(),
        };
        let (a, b) = time_line.split_once("-->").ok_or_else(bad)?;
        let start_ms = parse_ts(a).ok_or_else(bad)?;
        let end_ms = parse_ts(b.split_whitespace().next().unwrap_or_default()).ok_or_else(bad)?;
        let text = lines.collect::<Vec<_>>().join("\n");
        cues.push(BilingualCue {
            id: cues.len() as u32 + 1,
            start_ms,
            end_ms,
            original: text,
            translation: None,
        });
    }
    cues.sort_by_key(|c| c.start_ms);
    Ok(cues)
}

/// 내보내기 형식
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Track {
    Original,
    Translation,
    /// 원문 줄 아래에 번역 줄을 붙인 이중 자막
    Dual,
}

pub fn write(cues: &[BilingualCue], track: Track) -> String {
    let mut out = String::new();
    for (n, c) in cues.iter().enumerate() {
        let text = match (track, &c.translation) {
            (Track::Original, _) | (Track::Dual, None) => c.original.clone(),
            (Track::Translation, t) => t.clone().unwrap_or_default(),
            (Track::Dual, Some(t)) => format!("{}\n{}", c.original, t),
        };
        out.push_str(&format!(
            "{}\n{} --> {}\n{}\n\n",
            n + 1,
            fmt_ts(c.start_ms),
            fmt_ts(c.end_ms),
            text
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\u{feff}1\r\n00:00:01,000 --> 00:00:03,500\r\nHello there.\r\n\r\n2\r\n00:01:02,250 --> 00:01:04,000\r\nHow are you?\r\nFine.\r\n";

    #[test]
    fn parse_basic() {
        let cues = parse(SAMPLE).unwrap();
        assert_eq!(cues.len(), 2);
        assert_eq!((cues[0].start_ms, cues[0].end_ms), (1000, 3500));
        assert_eq!(cues[1].start_ms, 62_250);
        assert_eq!(cues[1].original, "How are you?\nFine.");
    }

    #[test]
    fn roundtrip_dual() {
        let mut cues = parse(SAMPLE).unwrap();
        cues[0].translation = Some("안녕하세요.".into());
        let dual = write(&cues, Track::Dual);
        assert!(dual.contains("00:00:01,000 --> 00:00:03,500\nHello there.\n안녕하세요.\n"));
        assert_eq!(
            parse(&write(&cues, Track::Original)).unwrap(),
            parse(SAMPLE).unwrap()
        );
    }

    #[test]
    fn bad_timecode() {
        assert!(parse("1\nnot a time\nx\n").is_err());
    }
}
