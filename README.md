# Hyper-V GPU 顯示卡直通虛擬機一鍵腳本設定

[繁體中文](README.md) | [English](README_EN.md)

## 名詞解釋

- **Host Windows**：安裝在實體電腦上、負責執行 Hyper-V 與此腳本的 Windows 作業系統。實體 GPU 由 Host Windows 管理。
- **VM（Virtual Machine）**：由 Hyper-V 建立與管理的虛擬機器。
- **Guest Windows**：安裝並執行在 VM 內部的 Windows 作業系統。
- **實體 GPU**：安裝在實體電腦中的顯示卡；GPU-P 會將它的部分資源提供給 VM 使用。

## 此腳本簡要描述

本文使用 `Host Windows` 與 `Guest Windows` 區分 VM 外部及內部的 Windows；需要描述硬體本身時則使用「實體電腦」或「實體 GPU」。

`Setup-GpuP-Portable.ps1` 用來在 Host Windows 上替 VM 設定 GPU Partitioning（GPU-P）。GPU-P 可讓 Host Windows 與一台或多台 VM 共享同一張實體 GPU，而不需要將整張 GPU 專屬直通給單一 VM。

腳本會讓你選擇 VM、Host Windows 管理的實體 GPU，以及 Guest Windows 所在的虛擬磁碟。接著，腳本會把 Host Windows 目前使用中的 GPU 驅動檔案複製到離線 Guest Windows 的指定目的地，設定 VM 的記憶體映射 I/O 與快取選項，最後新增所選 GPU 的分割區介面卡。

## 適用情境

- **遊戲多開或多帳號隔離**：建立多台安裝 Guest Windows 的 VM，在不同 VM 中分別執行遊戲客戶端，並讓它們共享實體 GPU。適合需要隔離登入環境、設定檔或應用程式資料的情境。
- **Host Windows 與 VM 同時使用 GPU**：Host Windows 保留桌面與日常工作環境，同時讓 VM 使用 GPU 加速，不必為 VM 準備另一張獨立顯示卡。
- **多套軟體環境測試**：在不同 VM 中測試驅動程式、遊戲、圖形應用程式或 Windows 設定，降低測試內容影響 Host Windows 的風險。
- **圖形與運算工作負載**：讓 VM 使用支援的 3D、影片處理、渲染或 GPU 運算功能；實際可用功能取決於 GPU、驅動程式與應用程式相容性。

GPU-P 是共享資源，不代表每台 VM 都能獲得完整實體 GPU 的效能。可同時執行的 VM 或遊戲數量會受 GPU 效能與顯示記憶體、CPU、系統記憶體及工作負載影響。此外，部分遊戲的防作弊系統、授權條款或虛擬化偵測可能禁止或無法在 VM 中運作；使用前應確認遊戲規則與相容性。

此腳本只負責設定單台 VM 的 GPU-P 介面卡與必要驅動檔案，不會安裝遊戲、建立 VM、調整遊戲設定或自動啟動多個 VM。若要讓多台 VM 使用 GPU，需要對每台 VM 分別執行設定。

腳本不會自動啟動虛擬機。完成後需要自行啟動 VM，並在 Guest Windows 的「裝置管理員」中確認顯示卡是否正常運作。

## 執行需求

- 在已啟用 Hyper-V 的 Host Windows 上執行。
- 使用 Windows PowerShell 5.1，並以系統管理員身分執行。
- 實體 GPU 必須支援 Hyper-V GPU Partitioning，且 Host Windows 已安裝可正常使用的 GPU 驅動程式。
- Guest Windows 必須是 x64 版本的 Windows 10 或 Windows 11。
- 執行前必須將 VM 完整關機（**一定要完整關機，而不是儲存**）。
- Guest Windows 的虛擬磁碟不可已被其他程式掛載，且 Windows 磁碟區必須可直接讀取。若磁碟受 BitLocker 鎖定，腳本將無法寫入驅動檔案。
- 如果要建立完整 VM 備份，備份位置必須有足夠空間容納 Hyper-V 匯出的設定與虛擬磁碟。

## 腳本會進行的變更

1. 從 Host Windows 收集所選 GPU 的驅動套件與相關檔案。
2. 依照選擇建立新 VM 備份、沿用既有備份，或略過備份。
3. 暫時掛載所選虛擬磁碟，將驅動檔案複製到 Guest Windows，並以 SHA-256 驗證複製結果。
4. 卸載虛擬磁碟後，設定 VM 的 `GuestControlledCacheTypes`、Low MMIO 與 High MMIO。
5. 將所選的實體 GPU 設為該 VM 的 GPU 分割區介面卡。

腳本會在複製驅動前先建立檔案清單與記錄目錄。若選擇略過備份，所有變更會直接寫入虛擬磁碟，發生問題時不會有由此腳本建立的 Hyper-V 匯出備份可供復原。

## 快速開始

1. 將此腳本放在 Host Windows 的任意資料夾。
2. 將目標 VM 從 Guest Windows 內完整關機 **（一定要完整關機，而不是儲存）**。
3. 請確認目標 VM 的檢查點為「停用」。
4. 以系統管理員身分開啟 Windows PowerShell 5.1。
5. 切換至包含腳本的資料夾，例如：

   ```powershell
   Set-Location "C:\Hyper-V-GpuP-Scripts"
   ```

6. 執行腳本：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1"
   ```

7. 依提示選擇 VM、GPU、包含 Guest Windows 的虛擬磁碟，以及備份方式。
8. 看到 `SUCCESS` 後，自行啟動 VM，並在裝置管理員中檢查 GPU 狀態。

執行期間請勿啟動 VM、中途會掛載 VM 的虛擬磁碟在 Host Windows 中，如有出現新的磁碟機視窗出現，請不予理會待工作完成後就會自動卸除，也請不要切斷實體電腦電源。

如果腳本失敗，請先確認終端機顯示的虛擬磁碟已成功卸除，再嘗試啟動 VM。

## 可用參數

| 參數 | 類型 | 預設值 | 說明 |
| --- | --- | --- | --- |
| `-LogRoot <路徑>` | 字串 | 腳本目錄下的 `GpuP-Logs` | 指定執行記錄的根目錄。每次執行會建立一個以時間與隨機 ID 命名的子目錄，並在其中寫入 `Files.csv`。 |
| `-BackupRoot <路徑>` | 字串 | 未指定 | 指定新 VM 完整備份的根目錄。選擇建立新備份時，腳本會在此目錄下建立一個執行 ID 子目錄。如果未指定，腳本會詢問備份位置，預設為本次記錄目錄下的 `VM-Backup`。 |
| `-ReuseBackupPath <路徑>` | 字串 | 未指定 | 指定要搜尋並沿用的既有 Hyper-V 匯出備份。該路徑下必須恰好有一份與所選 VM ID 相符且包含虛擬磁碟的匯出備份。使用後不會建立新備份。 |
| `-SkipBackup` | 開關 | 關閉 | 略過既有備份搜尋與新 VM 備份，直接修改虛擬磁碟。此選項不能與 `-ReuseBackupPath` 同時使用。 |

路徑參數支援環境變數。相對路徑會以啟動腳本時 PowerShell 的目前目錄為基準解析。

## 備份選項

只有在 `-ReuseBackupPath` 與 `-SkipBackup` 都未指定時，腳本才會顯示下列互動式備份選單。指定其中一個參數後不會出現備份選單，但選擇 VM、GPU 與虛擬磁碟等其他互動式選單仍會照常出現。

- 輸入 `0`：建立新的完整 VM 備份。
- 輸入既有備份的編號：沿用該份備份。
- 輸入 `S`：略過備份。
- 輸入 `Q`：取消執行。

略過備份會直接寫入 VM 的虛擬磁碟，且不會留下可供復原的 Hyper-V 匯出備份。

## 使用範例

將記錄寫入指定位置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -LogRoot "D:\GpuP-Logs"
```

將新備份建立於指定根目錄：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -BackupRoot "E:\Hyper-V-Backups"
```

沿用既有備份：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -ReuseBackupPath "E:\Hyper-V-Backups\20261014-120000-abcd1234"
```

直接略過備份：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -SkipBackup
```

同時指定記錄與新備份根目錄：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Setup-GpuP-Portable.ps1" -LogRoot "D:\GpuP-Logs" -BackupRoot "E:\Hyper-V-Backups"
```

## 參考資料

1. [GPU 分割](https://learn.microsoft.com/zh-tw/windows-server/virtualization/hyper-v/gpu-partitioning)
2. [分割 GPU 並指派給虛擬機器](https://learn.microsoft.com/zh-tw/windows-server/virtualization/hyper-v/partition-assign-vm-gpu?tabs=windows-admin-center)

## 支持這個專案

對腳本有任何問題，歡迎開 Issue 讓我知道

想貢獻程式碼，也歡迎 Fork 此專案後開 Pull Request（PR）給我，謝謝！

若這個腳本對你有幫助，請不吝給這個專案一個 ⭐ Star！
