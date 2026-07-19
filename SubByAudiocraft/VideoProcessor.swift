import Foundation
import AVFoundation
import WhisperKit
import Photos
import ffmpegkit
import CoreText

class VideoProcessor: ObservableObject {
    static let shared = VideoProcessor()
    
    // Uygulama içi fısıltı sonuçları (Identifiable, Hashable ve Codable uyumlu)
    struct WordTimestamp: Identifiable, Hashable, Codable {
        var id = UUID()
        var text: String
        var start: Double
        var end: Double
    }
    
    // 1. Sesi Videodan Çıkarma
    // 1. Sesi Videodan 16kHz Mono WAV (PCM) Olarak Çıkarma (Siri ses tanıma motorunun yarıda kesilmesini önler)
    func extractAudio(from videoURL: URL, completion: @escaping (URL?) -> Void) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        let inPath = videoURL.path
        let outPath = outputURL.path

        // Whisper için ideal format: 16kHz, Tek Kanal (Mono), 16-bit PCM WAV
        // Not: Bandpass filtresi kullanılmıyor; Whisper tam bant ses ile eğitildiği için
        // 3kHz üstünü kesmek ünsüz seslerini silip transkripsiyon kalitesini düşürür.
        let args = [
            "-y",
            "-i", inPath,
            "-vn",
            "-acodec", "pcm_s16le",
            "-ar", "16000",
            "-ac", "1",
            outPath
        ]
        
        FFmpegKit.execute(withArgumentsAsync: args) { session in
            guard let session = session else {
                completion(nil)
                return
            }
            
            let returnCode = session.getReturnCode()
            if ReturnCode.isSuccess(returnCode) {
                completion(outputURL)
            } else {
                let logs = session.getLogsAsString() ?? ""
                print("FFmpeg ses çıkarma hatası: \(logs)")
                completion(nil)
            }
        }
    }
    
    // Model bir kez yüklenir ve sonraki analizlerde tekrar kullanılır (her seferinde yeniden yüklemek çok yavaştır)
    private var cachedWhisperKit: WhisperKit?

    // Model tercih sırası: large-v3-turbo'nun 626 MB'lık nicelenmiş hali Türkçe'de
    // (özellikle şarkı/türkü sözlerinde) small'dan ÇOK daha isabetlidir ve boyutu
    // small (~500 MB) ile hemen hemen aynıdır. İndirilemez veya cihaz kaldıramazsa
    // sıradaki modele düşülür; small en garantili yedektir.
    private let modelAdaylari = [
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-small"
    ]

    // Aday listesindeki ilk çalışan modeli indirir ve yükler
    private func enIyiModeliYukle(downloadProgress: @escaping (Double) -> Void) async throws -> WhisperKit {
        var sonHata: Error?
        for aday in modelAdaylari {
            do {
                let modelFolder = try await WhisperKit.download(
                    variant: aday,
                    progressCallback: { progress in
                        downloadProgress(progress.fractionCompleted)
                    }
                )
                downloadProgress(1.0)

                let config = WhisperKitConfig(modelFolder: modelFolder.path)
                return try await WhisperKit(config)
            } catch {
                print("Model '\(aday)' yüklenemedi, sıradakine geçiliyor: \(error.localizedDescription)")
                sonHata = error
            }
        }
        throw sonHata ?? NSError(domain: "VideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Hiçbir yapay zeka modeli yüklenemedi."])
    }

    // 2. Yapay Zeka WhisperKit (CoreML) ile Sesi Metne Çevirme (Python hassasiyetinde kelime kelime zamanlama)
    // downloadProgress: model ilk kez indirilirken 0.0-1.0 arası ilerleme bildirir
    func runSpeechRecognition(audioURL: URL, downloadProgress: @escaping (Double) -> Void, completion: @escaping ([WordTimestamp], String?) -> Void) {
        Task {
            do {
                // 1. Model Klasörünü Hazırla (İlk çalıştırmada modeli Hugging Face'den indirir ve kaydeder)
                // Cihazın Neural Engine / Metal hızlandırıcılarını kullanarak yerel olarak deşifre eder.
                let whisperKit: WhisperKit
                if let cached = self.cachedWhisperKit {
                    whisperKit = cached
                } else {
                    whisperKit = try await self.enIyiModeliYukle(downloadProgress: downloadProgress)
                    self.cachedWhisperKit = whisperKit
                }

                // 2. Kod çözme ayarları (Türkçe dili ve kelime düzeyinde zaman damgaları)
                var options = DecodingOptions()
                options.language = "tr"
                options.wordTimestamps = true

                // 3. Deşifre etme işlemini başlatıyoruz
                let results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)
                
                // 4. Sonuçlardaki segmentleri kelime kelime ayrıştırıp diziye ekliyoruz
                var words: [WordTimestamp] = []
                
                for result in results {
                    // Not: Bu WhisperKit sürümünde segments opsiyonel değildir; doğrudan geziyoruz
                    for segment in result.segments {
                        // Kelime düzeyinde zaman damgaları (Word-level timestamps) varsa alıyoruz
                        if let segmentWords = segment.words, !segmentWords.isEmpty {
                            for word in segmentWords {
                                let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .replacingOccurrences(of: "[.,!?;:]", with: "", options: .regularExpression)
                                if !text.isEmpty {
                                    words.append(WordTimestamp(
                                        text: text,
                                        start: Double(word.start),
                                        end: Double(word.end)
                                    ))
                                }
                            }
                        } else {
                            // Eğer kelime zaman damgası yoksa segmenti kelimelere bölüp süreyi orantılı dağıtıyoruz
                            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            let rawWords = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                            let duration = Double(segment.end) - Double(segment.start)
                            let wordDur = duration / Double(max(1, rawWords.count))

                            for (index, wordText) in rawWords.enumerated() {
                                let cleanText = wordText.replacingOccurrences(of: "[.,!?;:]", with: "", options: .regularExpression)
                                if !cleanText.isEmpty {
                                    let start = Double(segment.start) + (Double(index) * wordDur)
                                    words.append(WordTimestamp(
                                        text: cleanText,
                                        start: start,
                                        end: start + wordDur
                                    ))
                                }
                            }
                        }
                    }
                }
                
                if words.isEmpty {
                    completion([], "Videoda deşifre edilebilecek net bir konuşma bulunamadı.")
                } else {
                    completion(words, nil)
                }
                
            } catch {
                print("WhisperKit hatası: \(error.localizedDescription)")
                completion([], "WhisperKit yapay zeka analiz hatası: \(error.localizedDescription)")
            }
        }
    }
    
    // Font PostScript isimlerini libass/fontconfig'in tanıyacağı Font Family isimlerine dönüştürür.
    private func getFontFamilyName(for fontName: String) -> String {
        if let secenek = FontCatalog.secenek(fontName) { return secenek.assFamily }
        return fontName.replacingOccurrences(of: "-Bold", with: "").replacingOccurrences(of: "-Heavy", with: "").replacingOccurrences(of: "-Regular", with: "")
    }
    
    // Kelimeler arası boşluk ve satır uzunluğuna göre otomatik satır önerisi üretir
    // (en fazla 4 kelime / ~18 karakter; 0.8 sn'den uzun boşlukta yeni satır)
    func autoLineGroups(for words: [WordTimestamp]) -> [[WordTimestamp]] {
        var groups: [[WordTimestamp]] = []
        var current: [WordTimestamp] = []
        var currentChars = 0

        for word in words {
            let wordLength = word.text.count
            if let lastWord = current.last {
                let gap = word.start - lastWord.end
                if current.count >= 4 || currentChars + wordLength > 18 || gap > 0.8 {
                    groups.append(current)
                    current = []
                    currentChars = 0
                }
            }
            current.append(word)
            currentChars += wordLength + 1
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // Otomatik önerinin "satır sonu" kelime kimliklerini döndürür (satır düzenleyici için)
    func autoLineBreaks(for words: [WordTimestamp]) -> Set<UUID> {
        var result = Set<UUID>()
        for group in autoLineGroups(for: words) {
            if let last = group.last { result.insert(last.id) }
        }
        return result
    }

    // 3. ASS Altyazı Dosyası Oluşturma (iOS 16+ uyumlu asenkron yapı)
    // lineBreaks: kullanıcının onayladığı satır sonları (boşsa otomatik öneri kullanılır)
    func generateASS(words: [WordTimestamp], lineBreaks: Set<UUID>, fontName: String, fontSize: Int, marginV: Int, videoURL: URL) async -> URL? {
        let asset = AVAsset(url: videoURL)
        
        // Modern async API'ler ile video izlerini yükleme
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return nil }
              
        // Deprecated naturalSize yerine load(.naturalSize) kullanımı
        guard let size = try? await track.load(.naturalSize) else { return nil }

        // Rotasyon metadatasını hesaba kat: dikey çekilen videolar naturalSize'ı yatay raporlar.
        // preferredTransform uygulanmazsa dikey videolarda font oranı ve konum bozulur.
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let rotatedRect = CGRect(origin: .zero, size: size).applying(transform)

        let width = Double(abs(rotatedRect.width))
        let height = Double(abs(rotatedRect.height))
        guard width > 0, height > 0 else { return nil }

        let aspectRatio = width / height
        let virtualHeight = 1080
        let virtualWidth = Int(1080.0 * aspectRatio)
        
        let familyName = getFontFamilyName(for: fontName)

        // Bold bayrağı yalnız gerçekten kalın kesimi olan fontlarda açılır. Eskiden her font
        // için -1 (açık) yazılıyordu; kalın kesimi olmayan fontlarda libass yapay kalınlaştırma
        // uyguluyor ve gömülen yazı ön izlemedekinden farklı ("font değişmiş gibi") görünüyordu.
        let boldFlag = (FontCatalog.secenek(fontName)?.kalin ?? fontName.contains("Bold")) ? -1 : 0

        // Bitişik (el yazısı) fontlarda harf başına etiket bloğu, animasyon sırasında harf
        // bağlarını/konturu koparıp harfi "normal" gösteriyordu. Çözüm iki katman hilesi:
        // altta etiketsiz BİTİŞİK soluk kopya (hiç bozulmaz), üstte harf harf tam saydama
        // ERİYEN opak kopya. Harf harf soluklaşma hissi korunur, yazı hep bitişik görünür.
        let bitisikFont = FontCatalog.secenek(fontName)?.bitisik ?? false

        var assContent = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(virtualWidth)
        PlayResY: \(virtualHeight)

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(familyName),\(fontSize),&H00FFFFFF,&H000000FF,&H00000000,&H00000000,\(boldFlag),0,0,0,100,100,0,0,1,3,1.5,2,10,10,\(marginV),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        
        // Satır grupları: kullanıcının satır düzenleyicide onayladığı düzen esas alınır;
        // satır sonu bilgisi yoksa otomatik öneri kullanılır.
        var groups: [[WordTimestamp]] = []
        if lineBreaks.isEmpty {
            groups = autoLineGroups(for: words)
        } else {
            var currentGroup: [WordTimestamp] = []
            for word in words {
                currentGroup.append(word)
                if lineBreaks.contains(word.id) {
                    groups.append(currentGroup)
                    currentGroup = []
                }
            }
            if !currentGroup.isEmpty { groups.append(currentGroup) }
        }

        // Efekt (kullanıcının Python sistemiyle birebir aynı):
        // Satırın tamamı TAM GÖRÜNÜR (&H00&) gelir; her harf, söylendiği anda
        // yarı saydama (&HA0&) soluklaşır. Satır 0.2 sn erken görünüp 0.2 sn geç kaybolur.
        //
        // ÖNEMLİ: Ardışık satırların zaman aralıkları KESİNLİKLE çakışmamalıdır.
        // İki Dialogue satırı aynı anda ekrandaysa libass onları üst üste istifler:
        // yeni satır önce yukarıda belirir, eski satır kaybolunca aşağı zıplar
        // ("yazı hareket ediyor / font değişip geliyor" şikayetinin kaynağı buydu).
        // Bu yüzden komşu satırlar arasında TEK ortak sınır hesaplanır ve bir imleç
        // (cursor) ile hiçbir satırın bir öncekinden erken başlamaması garanti edilir.
        var rawSegs: [(start: Double, end: Double, group: [WordTimestamp])] = []
        for group in groups {
            guard let firstWord = group.first, let lastWord = group.last else { continue }
            let rawStart = max(0, firstWord.start)
            let rawEnd = max(rawStart + 0.2, lastWord.end)
            rawSegs.append((rawStart, rawEnd, group))
        }

        var boundaries: [Double] = []
        if rawSegs.count > 1 {
            for i in 0..<(rawSegs.count - 1) {
                boundaries.append((rawSegs[i].end + rawSegs[i + 1].start) / 2)
            }
        }

        var cursor = 0.0
        for (index, seg) in rawSegs.enumerated() {
            var segStart = max(0, seg.start - 0.2)
            if index > 0 { segStart = max(segStart, boundaries[index - 1]) }
            segStart = max(segStart, cursor)

            var segEnd = seg.end + 0.2
            if index < rawSegs.count - 1 { segEnd = min(segEnd, boundaries[index]) }
            // En az 0.2 sn görünürlük; imleç sayesinde bu uzatma da çakışma yaratamaz
            if segEnd < segStart + 0.2 { segEnd = segStart + 0.2 }
            cursor = segEnd

            var effectText = ""   // normal fontlar: tek katman; bitişik fontlar: üstteki eriyen katman
            var plainText = ""    // bitişik fontlar: alt katmanın etiketsiz tam metni
            for word in seg.group {
                // ASS formatını bozabilecek özel karakterleri temizle ({, }, \ ve satır sonları)
                let cleanText = word.text
                    .replacingOccurrences(of: "\\", with: "")
                    .replacingOccurrences(of: "{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanText.isEmpty { continue }

                // Kelime zamanlarını kelepçele (ters girilmiş süreleri de düzeltir)
                let wordStart = max(segStart, word.start)
                let wordEnd = max(wordStart + 0.05, word.end)

                let chars = Array(cleanText)
                let letterDur = (wordEnd - wordStart) / Double(chars.count)

                // Bitişik fontta üst katman harfi TAM SAYDAMA (&HFF&) erir — alttaki soluk
                // bitişik kopya belirir. Normal fontta harf doğrudan yarı saydama (&HA0&) iner.
                let hedefAlpha = bitisikFont ? "FF" : "A0"

                for (i, char) in chars.enumerated() {
                    let lStartMs = Int((wordStart + Double(i) * letterDur - segStart) * 1000)
                    let lEndMs = Int((wordStart + Double(i + 1) * letterDur - segStart) * 1000)
                    let fadeEnd = max(lStartMs + 20, min(lEndMs, lStartMs + 100))
                    effectText += "{\\alpha&H00&\\t(\(lStartMs),\(fadeEnd),\\alpha&H\(hedefAlpha)&)}\(char)"
                }

                effectText += " "
                plainText += cleanText + " "
            }

            if effectText.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if bitisikFont {
                // İki katman: alttaki (Layer 0) etiketsiz satır libass'ta tek parça
                // şekillenir — harf bağları ve kontur her karede bitişik kalır. Üstteki
                // (Layer 1) opak kopyanın harfleri sırası geldikçe eriyip altı ortaya
                // çıkarır. Farklı Layer değerleri üst üste çizilir, istifleme yapmaz.
                assContent += "Dialogue: 0,\(formatASSTime(segStart)),\(formatASSTime(segEnd)),Default,,0,0,0,,{\\alpha&HA0&}\(plainText)\n"
                assContent += "Dialogue: 1,\(formatASSTime(segStart)),\(formatASSTime(segEnd)),Default,,0,0,0,,\(effectText)\n"
            } else {
                assContent += "Dialogue: 0,\(formatASSTime(segStart)),\(formatASSTime(segEnd)),Default,,0,0,0,,\(effectText)\n"
            }
        }
        
        let assURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ass")
        do {
            try assContent.write(to: assURL, atomically: true, encoding: .utf8)
            return assURL
        } catch {
            print("Failed to write ASS file: \(error)")
            return nil
        }
    }
    
    // Filtre argümanlarında geçebilecek özel karakterleri FFmpeg için escape eder
    private func escapeForFilter(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    // Seçilen fontun GERÇEK dosyasını CoreText üzerinden bulup geçici bir klasöre kopyalar.
    // Bu klasör libass'a fontsdir ile doğrudan verilir: fontconfig'in sistem klasörü
    // taraması bazı sistem fontlarını bulamıyor ve libass sessizce varsayılan fonta
    // düşüyordu ("video, ön izlemedeki fonttan farklı çıkıyor" şikayetinin nedeni).
    // Dosya bulunamazsa nil döner ve eski fontconfig yolu yedek olarak devrede kalır.
    private func prepareFontsDir(for fontName: String) -> URL? {
        let ctFont = CTFontCreateWithName(fontName as CFString, 24, nil)

        // CoreText istenen fontu bulamazsa sessizce başka bir fonta düşer;
        // yanlış dosyayı kopyalamamak için çözümlenen adı doğruluyoruz.
        let resolvedName = CTFontCopyPostScriptName(ctFont) as String
        guard resolvedName.caseInsensitiveCompare(fontName) == .orderedSame,
              let fontFileURL = CTFontCopyAttribute(ctFont, kCTFontURLAttribute) as? URL else {
            return nil
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ass_fonts_" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fontFileURL, to: dir.appendingPathComponent(fontFileURL.lastPathComponent))
            return dir
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    // 4. FFmpegKit ile Videoyu Oluşturma
    func burnSubtitles(videoURL: URL, assURL: URL, fontName: String, completion: @escaping (URL?, String?) -> Void) {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")

        // Yedek yol: fontconfig sistem klasörlerini de tanır (fontsdir başarısız olursa)
        FFmpegKitConfig.setFontDirectoryList([
            Bundle.main.bundlePath,
            "/System/Library/Fonts",
            "/System/Library/Fonts/Core",
            "/System/Library/Fonts/CoreAddition",
            "/System/Library/Fonts/CoreUI",
            "/System/Library/Fonts/AppFonts",
            "/System/Library/Fonts/Extra"
        ], with: nil)

        // Asıl yol: seçilen fontun dosyası libass'a doğrudan verilir
        let fontsDir = prepareFontsDir(for: fontName)

        let inPath = videoURL.path
        let outPath = outputURL.path

        var vfString = "ass='\(escapeForFilter(assURL.path))'"
        if let fontsDir = fontsDir {
            vfString += ":fontsdir='\(escapeForFilter(fontsDir.path))'"
        }
        
        // Hardware accelerated encoding on iOS using h264_videotoolbox. Much faster and uses less battery.
        // -allow_sw 1: donanım kodlayıcı kullanılamazsa yazılım kodlayıcıya düşerek çökmesini önler.
        // 12M bitrate 1080p için yüksek kalite sağlar; 30M gereksiz büyük dosyalar üretiyordu.
        let args = [
            "-y",
            "-i", inPath,
            "-vf", vfString,
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-b:v", "12M",
            "-movflags", "+faststart",
            "-c:a", "copy",
            outPath
        ]

        FFmpegKit.execute(withArgumentsAsync: args) { session in
            // Kodlama bitti; geçici font kopyası artık gerekmez
            if let fontsDir = fontsDir {
                try? FileManager.default.removeItem(at: fontsDir)
            }

            guard let session = session else {
                completion(nil, "Bilinmeyen bir oturum hatası")
                return
            }

            let returnCode = session.getReturnCode()

            if ReturnCode.isSuccess(returnCode) {
                completion(outputURL, nil)
            } else if ReturnCode.isCancel(returnCode) {
                completion(nil, "İşlem iptal edildi.")
            } else {
                let logs = session.getLogsAsString() ?? "Log alınamadı"
                print("FFMPEG HATASI: \(logs)")
                // Tam logu veya en azından son 5000 karakteri göstererek hatayı yakalıyoruz
                let shortLog = String(logs.suffix(5000))
                completion(nil, shortLog)
            }
        }
    }
    
    // 5. Videoyu Galeriye Kaydet (iOS 14+ addOnly ile daha güvenli ve detaylı hata dönüşlü)
    func saveToGallery(videoURL: URL, completion: @escaping (Bool, String?) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized {
            performSave(videoURL: videoURL, completion: completion)
        } else {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized {
                    self.performSave(videoURL: videoURL, completion: completion)
                } else {
                    completion(false, "Galeriye kaydetme izni reddedildi. Lütfen Ayarlar'dan izin verin.")
                }
            }
        }
    }
    
    private func performSave(videoURL: URL, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }) { success, error in
            if success {
                completion(true, nil)
            } else {
                completion(false, error?.localizedDescription ?? "Bilinmeyen galeri kaydetme hatası.")
            }
        }
    }
    
    // Geçici dosyaları silerek telefon hafızasının şişmesini önler.
    func deleteFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    private func formatASSTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let cs = Int(round((seconds - floor(seconds)) * 100))
        return String(format: "%d:%02d:%02d.%02d", h, m, s, min(cs, 99))
    }
}
