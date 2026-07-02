# CaptionLab（繁體中文）

[English](README.md) | **繁體中文**

一個 macOS SwiftUI app + 無頭 CLI 的 **LLM 輔助字幕校正實驗室**：讓 Apple 裝置端語音辨識與 Google
Gemini **互相對質**，對真實世界的語音（講太快、含糊、術語密集、中英夾雜）產出準確、卡拉OK級對時、
可直接剪輯的字幕。

源自 [Palmier Pro](https://github.com/palmier-io/palmier-pro) 的 fork：上游只用 Apple
`SpeechTranscriber`；這裡所有 LLM 側的部分（content map、修正、補聽、贅詞標記）都是本實驗室加的，
獨立開發以便量測、A/B 驗證，再回移。零外部套件依賴，只用系統框架。

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

每支 clip 固定**兩次**語意呼叫（+視需要補聽）。判斷只做一次，所以字幕文字和剪單永遠一致。

### Pipeline 七階段

| # | 階段 | 引擎 |
|---|------|------|
| 1 | Content map——看完整支影片：逐字對白分塊、說話者標籤、摘要、術語清單 | Gemini（影片） |
| 2 | ASR + 前置音訊調理（正規化/壓縮；快語音放慢為實驗選項） | Apple 裝置端 |
| 3 | 詞彙表——map 挖出的術語 + 手動清單合併（不另外呼叫） | — |
| 4 | 修正——唯一的判斷呼叫（文字+標點+¦+⟦⟧+⟨⟩），鎖字數保時間軸 | Gemini（文字） |
| 5 | 補聽——修正後仍與 map 差很大的段落重聽、拼回、能量峰配時 | Gemini（音訊，可關） |
| 6 | 剪贅詞——機械執行 ⟨⟩ 標記；離線時退回 heuristic | — |
| 7 | 時間軸自檢——驗證每字時間 1:1 保留（drift 必須為 0） | — |

### 功能

- **音質報告**：每支 clip 的爆音 %、SNR 估計、背景音樂區段（Apple SoundAnalysis）。
- **換人斷句**：map 的說話者標籤帶進修正，主持人→來賓零停頓交接也會切行；跨說話者的重複接話
  不會被誤判成結巴。
- **手動字幕編輯**：點時間跳播放、就地改字（Enter 切成兩行）、併入下一行；沒改的字保留原時間，
  改過的段落用音節能量峰重配。
- **Gemini 用量/費用儀表板**：按模型統計 token 與費用（官方費率）。
- **Qwen（MLX）forced-aligner A/B 車道**（選配，`./setup.sh`）。
- **標注逐字稿 JSON**（`--dump-json`）：segment 帶 text/start/end/captionBreaks/cutUnits——
  可攜的交換文件，任何 NLE 匯出器（SRT、FCPXML、剪單）都能讀取。
- `--cli --audio-check <media>`：純裝置端診斷（音質、調理、ASR A/B），不需要 API key。

### 需求與建置

- Apple Silicon、macOS 26+、**完整 Xcode**；LLM 階段需要 `GEMINI_API_KEY`（GUI 欄位或 `.env`）。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
./run.sh        # GUI
swift run CaptionLab --cli <media> [--model gemini-pro-latest] [--dump-json out/]
```

### 實驗筆記（完整記錄見 DEVLOG.md）

- **獨立性就是火力來源**：content map 從不看 ASR 文字，它的第二意見才能抓到「單看很合理」的同音字錯。
  合併兩次呼叫只省 ~$0.003，卻會毀掉整個機制。
- **鎖字數**：修正可以換字、不可增刪音節——Apple 的每字時鐘因此無損（全部測試片 drift 0）。
  掉音節交給補聽階段。
- **付過學費的負面結果**：辨識前把快語音放慢是「換錯不減錯」；forced aligner（Qwen）的時間品質比
  Apple ASR 邊界差，Qwen 的 A/B 車道仍保留在 app 內，歡迎自行重現這個比較；讓 LLM 看裸字清單決定剪誰會誤砍中文疊詞（常常）——直到剪標併入句子級判斷才根治。

測試素材為本機媒體（從未 commit），開發記錄中以中性代號指涉。

### 致謝與出處

- **方向**：[@JasChiang](https://github.com/JasChiang) 提供基礎架構想法與設計決策（感知/判斷/機械的
  分層、雙耳互相對質的路線、該做什麼與該否決什麼）——掌舵、用真實素材驗證、抓出 over-fitting。
- **實作**：程式碼幾乎全部由 **Claude Code**（Anthropic）在上述方向下完成——見 commit 歷史中的
  co-author 署名，包括它自己寫出來再自己抓到的 bug。
- **以 Apple `SpeechTranscriber` 作為 ASR 前端源自 [Palmier Pro](https://github.com/palmier-io/palmier-pro)**
  （上游專案，僅使用 Apple ASR）；LLM 各層為本實驗室新增。

### 授權

GPL-3.0（與上游一致）——見 `LICENSE` 與 `NOTICE`。
