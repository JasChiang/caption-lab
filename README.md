# CaptionLab

**English** | [繁體中文](#captionlab-繁體中文)

A macOS SwiftUI app **and** headless CLI for LLM-assisted caption correction — an experiment lab where
Apple's on-device speech recognition and Google Gemini cross-check each other to produce accurate,
karaoke-timed, edit-ready captions for real-world (fast, mumbled, jargon-heavy, code-switching) speech.

Grown out of a [PalmierPro](https://github.com/palmier-io/palmier-pro) fork: the upstream app uses Apple
`SpeechTranscriber` only; everything LLM-side here (content map, correction, re-listening, disfluency
marking) is this lab's addition, developed in isolation so the pipeline can be measured, A/B-tested, and
ported back. No external Swift package dependencies — system frameworks only (SwiftUI, AVFoundation,
Speech, SoundAnalysis, Accelerate).

## Architecture — perception / judgment / mechanics

```
PERCEPTION   Apple SpeechTranscriber ──── per-word timings (the only clock)
(two ears)   Gemini content map ────────── independent 2nd transcription + speakers + terms
                                           (never shown the ASR text — no anchoring)
                      │
JUDGMENT     ONE Gemini text call: corrects mishearings (homophones, code-switching),
(one pass)   adds punctuation, and emits ALL marks in the same judgment —
             ¦ caption line breaks · ⟦term⟧ never-split terms · ⟨disfluency⟩ words to cut
                      │
MECHANICS    deterministic, no AI: 1:1 timing writeback (LCS-aligned), energy-peak
(pure fn)    re-timing for recovered syllables, ripple-cut planning, valley-snapped
(portable)   cut boundaries, caption chunking. Ports to any NLE.
```

Two semantic calls per clip, total (plus optional per-span re-listening). One judgment pass means the
caption text and the cut list can never disagree.

### Pipeline stages

| # | Stage | Engine |
|---|-------|--------|
| 1 | Content map — watch the whole clip: verbatim dialogue blocks, speaker labels, summary, harvested terms | Gemini (video) |
| 2 | ASR with pre-conditioning (normalize/compress; experimental slow-down for fast speech) | Apple, on-device |
| 3 | Glossary — map-harvested terms merged with a manual list (no extra call) | — |
| 4 | Correction — the one judgment pass (text + punctuation + ¦ + ⟦⟧ + ⟨⟩), count-locked to preserve timing | Gemini (text) |
| 5 | Re-listen suspect spans where correction still disagrees with the map; splice + energy-peak re-timing | Gemini (audio, opt-in) |
| 6 | Cut disfluencies — executes the ⟨⟩ marks mechanically; heuristic fallback offline | — |
| 7 | Timing self-check — verifies 1:1 word-timing preservation (drift must be 0) | — |

### Features

- **Audio quality report** per clip: clipping %, SNR estimate, background-music spans (Apple SoundAnalysis).
- **Speaker-aware caption breaks**: the map's speaker labels ride into correction, so a host→guest handoff
  splits the caption even with zero pause — and cross-speaker echoes are never mistaken for stutters.
- **Manual caption editor**: click a line to seek, edit in place (Enter splits a line), merge with next;
  unchanged text keeps its timing, changed runs re-time on syllable energy peaks.
- **Gemini usage/cost dashboard**: per-model token counts and cost estimates at official rates, per session.
- **Qwen (MLX) forced-aligner A/B lane** for comparing timing backends (optional, `./setup.sh`).
- **Annotated-transcript JSON** (`--dump-json`): segments carry text/start/end/captionBreaks/cutUnits —
  a portable interchange document any NLE exporter (SRT, FCPXML, ripple cut list) can consume.
- `--cli --audio-check <media>`: on-device diagnostics (quality, conditioning, ASR A/B) with no API key.

### Requirements

- Apple Silicon Mac, macOS 26+, **full Xcode** (SwiftUI macros need more than Command Line Tools)
- `GEMINI_API_KEY` for the LLM stages (paste into the GUI field, or put it in `.env` — see `run.sh`)

### Build & run

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
./run.sh                       # GUI (sources .env, launches the app)
swift run CaptionLab --cli <media> [--model gemini-pro-latest] [--dump-json out/]
swift run CaptionLab --cli --audio-check <media>    # no key needed
```

### Field notes (see DEVLOG.md for the full lab log)

- **Independence is the whole trick**: the content map never sees the ASR text, so its "second opinion" can
  catch same-sounding errors that look plausible alone. Merging the two calls would save ~$0.003 and
  destroy the mechanism.
- **Count-lock**: correction may swap words but never add/remove syllables — that's what keeps Apple's
  per-word clock intact (verified drift 0 across all test clips). Dropped syllables are the re-listen
  stage's job instead.
- **Negative results we paid for so you don't have to**: time-stretching fast speech before ASR *swaps*
  errors instead of reducing them; a forced aligner (Qwen) produced worse timing than Apple's ASR
  boundaries; per-word-list LLM cut decisions mis-cut CJK reduplications (常常) until cut marking moved
  into the sentence-level judgment pass.

Test clips are local media (never committed) referenced by neutral aliases in the dev log.

### Credits & provenance

- **Direction**: [@JasChiang](https://github.com/JasChiang) provided the architectural ideas and design
  decisions (the perception/judgment/mechanics split, the cross-checking approach, what to build and what
  to reject) — steering, testing on real clips, and calling out the over-fitting.
- **Implementation**: essentially all of the code was written by **Claude Code** (Anthropic) working under
  that direction — see the co-author trailers throughout the commit history, including the bugs it wrote
  and then had to find.
- **Apple `SpeechTranscriber` as the ASR front-end comes from [PalmierPro](https://github.com/palmier-io/palmier-pro)**
  (the upstream project, which uses Apple ASR only); the LLM layers were added in this lab.

### License

GPL-3.0, same as upstream — see `LICENSE` and `NOTICE` for provenance.

---

# CaptionLab(繁體中文)

一個 macOS SwiftUI app + 無頭 CLI 的 **LLM 輔助字幕校正實驗室**:讓 Apple 裝置端語音辨識與 Google
Gemini **互相對質**,對真實世界的語音(講太快、含糊、術語密集、中英夾雜)產出準確、卡拉OK級對時、
可直接剪輯的字幕。

源自 [PalmierPro](https://github.com/palmier-io/palmier-pro) 的 fork:上游只用 Apple
`SpeechTranscriber`;這裡所有 LLM 側的東西(content map、修正、補聽、贅詞標記)都是本實驗室加的,
獨立開發以便量測、A/B 驗證,再回移。零外部套件依賴,只用系統框架。

## 架構——感知 / 判斷 / 機械

```
感知(兩雙耳朵) Apple SpeechTranscriber ── 每字時間軸(唯一的時鐘)
                Gemini content map ─────── 獨立第二聽 + 說話者 + 術語
                                           (刻意不給它 ASR 文字——避免錨定)
                      │
判斷(只此一次) 一次 Gemini 文字呼叫:修聽錯(同音字、中英夾雜)、加標點,
                並在同一次判斷裡輸出所有標記——
                ¦ 字幕斷行 · ⟦術語⟧ 不可拆行 · ⟨贅詞⟩ 待剪
                      │
機械(純函數)   零 AI:1:1 時間回寫(LCS 對齊)、能量峰重配時間、
                ripple 剪輯規劃、谷點修邊、字幕分行。可移植到任何 NLE。
```

每支 clip 固定**兩次**語意呼叫(+按需補聽)。判斷只做一次,所以字幕文字和剪單永遠一致。

### Pipeline 七階段

| # | 階段 | 引擎 |
|---|------|------|
| 1 | Content map——看完整支影片:逐字對白分塊、說話者標籤、摘要、術語清單 | Gemini(影片) |
| 2 | ASR + 前置音訊調理(正規化/壓縮;快語音放慢為實驗選項) | Apple 裝置端 |
| 3 | 詞彙表——map 挖出的術語 + 手動清單合併(不另外呼叫) | — |
| 4 | 修正——唯一的判斷呼叫(文字+標點+¦+⟦⟧+⟨⟩),鎖字數保時間軸 | Gemini(文字) |
| 5 | 補聽——修正後仍與 map 差很大的段落重聽、拼回、能量峰配時 | Gemini(音訊,可關) |
| 6 | 剪贅詞——機械執行 ⟨⟩ 標記;離線時退回 heuristic | — |
| 7 | 時間軸自檢——驗證每字時間 1:1 保留(drift 必須為 0) | — |

### 功能

- **音質報告**:每支 clip 的爆音 %、SNR 估計、背景音樂區段(Apple SoundAnalysis)。
- **換人斷句**:map 的說話者標籤帶進修正,主持人→來賓零停頓交接也會切行;跨說話者的重複接話
  不會被誤判成結巴。
- **手動字幕編輯**:點時間跳播放、就地改字(Enter 切成兩行)、併入下一行;沒改的字保留原時間,
  改過的段落用音節能量峰重配。
- **Gemini 用量/費用儀表板**:按模型統計 token 與費用(官方費率)。
- **Qwen(MLX)forced-aligner A/B 車道**(選配,`./setup.sh`)。
- **標注逐字稿 JSON**(`--dump-json`):segment 帶 text/start/end/captionBreaks/cutUnits——
  可攜的交換文件,任何 NLE 匯出器(SRT、FCPXML、剪單)都能吃。
- `--cli --audio-check <media>`:純裝置端診斷(音質、調理、ASR A/B),不需要 API key。

### 需求與建置

- Apple Silicon、macOS 26+、**完整 Xcode**;LLM 階段需要 `GEMINI_API_KEY`(GUI 欄位或 `.env`)。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
./run.sh        # GUI
swift run CaptionLab --cli <media> [--model gemini-pro-latest] [--dump-json out/]
```

### 實驗筆記(完整記錄見 DEVLOG.md)

- **獨立性就是火力來源**:content map 從不看 ASR 文字,它的第二意見才能抓到「單看很合理」的同音字錯。
  合併兩次呼叫只省 ~$0.003,卻會毀掉整個機制。
- **鎖字數**:修正可以換字、不可增刪音節——Apple 的每字時鐘因此無損(全部測試片 drift 0)。
  掉音節交給補聽階段。
- **付過學費的負面結果**:辨識前把快語音放慢是「換錯不減錯」;forced aligner(Qwen)的時間品質比
  Apple ASR 邊界差;讓 LLM 看裸字清單決定剪誰會誤砍中文疊詞(常常)——直到剪標併入句子級判斷才根治。

測試素材為本機媒體(從未 commit),開發記錄中以中性代號指涉。

### 致謝與出處

- **方向**:[@JasChiang](https://github.com/JasChiang) 提供基礎架構想法與設計決策(感知/判斷/機械的
  分層、雙耳互相對質的路線、該做什麼與該否決什麼)——掌舵、用真實素材驗證、抓出 over-fitting。
- **實作**:程式碼幾乎全部由 **Claude Code**(Anthropic)在上述方向下完成——見 commit 歷史中的
  co-author 署名,包括它自己寫出來再自己抓到的 bug。
- **以 Apple `SpeechTranscriber` 作為 ASR 前端源自 [PalmierPro](https://github.com/palmier-io/palmier-pro)**
  (上游專案,僅使用 Apple ASR);LLM 各層為本實驗室新增。

### 授權

GPL-3.0(與上游一致)——見 `LICENSE` 與 `NOTICE`。
