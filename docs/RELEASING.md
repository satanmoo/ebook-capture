# 릴리스 절차

사용자는 Homebrew tap(`satanmoo/homebrew-tap`)으로 설치한다. 릴리스는 태그 하나로 시작한다.

## 1회 준비

1. GitHub에 `satanmoo/homebrew-tap` 저장소를 만든다 (이름은 반드시 `homebrew-` 로 시작)
2. [packaging/homebrew/ebook-capture.rb](../packaging/homebrew/ebook-capture.rb)를 그 저장소의 `Formula/ebook-capture.rb`로 복사한다

## 매 릴리스

1. `Sources/EbookCapture/CLI.swift`의 `version`을 올리고 커밋한다 (예: `1.1.0`)
2. 릴리스 전 확인: `swift test`, `bash scripts/e2e.sh preview`, `bash scripts/e2e.sh app 1`, `bash scripts/e2e.sh app 2`
3. 태그를 푸시한다
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
4. `release` 워크플로가 태그와 `version`이 같은지 확인하고, 테스트 후 Intel + Apple Silicon 공용 실행 파일을 GitHub Release에 올린다 (`ebook-capture-v1.1.0-macos.tar.gz`, `checksums.txt`)
5. tap 저장소의 `Formula/ebook-capture.rb`에서 `url`, `version`, `sha256`을 Release의 값으로 바꿔 커밋한다
6. 확인: `brew update && brew upgrade ebook-capture && ebook-capture --version`

## 참고

- 실행 파일은 ad-hoc 서명만 되어 있다. Homebrew로 받은 파일에는 격리(quarantine) 속성이 붙지 않아 공증 없이 실행된다. 브라우저로 직접 받은 경우에는 `xattr -d com.apple.quarantine ebook-capture`가 필요하다
- 접근성·화면 기록 권한은 실행 파일이 아니라 사용자의 터미널 앱에 주는 것이라, 업데이트해도 다시 허용할 필요가 없다
