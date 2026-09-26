# 릴리스 절차

릴리스는 GitHub Actions의 `release` 워크플로가 전부 처리한다. 버전만 입력하면 테스트, 공용 실행 파일(Apple Silicon + Intel) 빌드, GitHub Release 생성, Homebrew tap(`satanmoo/homebrew-tap`)의 formula 갱신까지 자동으로 진행된다. 사용자는 `brew install satanmoo/tap/ebook-capture`로 설치하고 `brew upgrade`로 업데이트한다.

## 1회 준비: tap 토큰 등록

워크플로의 기본 토큰(`GITHUB_TOKEN`)은 이 저장소 안에서만 쓸 수 있어서, `homebrew-tap`에 formula를 커밋하려면 별도 토큰이 필요하다.

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → **Generate new token**
   - Token name: `ebook-capture tap` 등
   - Expiration: 원하는 기간 (만료되면 아래 "실패했을 때" 참고)
   - Repository access: **Only select repositories** → `satanmoo/homebrew-tap`
   - Permissions → Repository permissions → **Contents: Read and write** (다른 권한은 주지 않는다)
2. 만든 토큰을 이 저장소의 secret으로 등록한다. 둘 중 하나로 하면 된다.
   - 웹: `satanmoo/ebook-capture` → Settings → Secrets and variables → Actions → New repository secret → 이름 `HOMEBREW_TAP_TOKEN`
   - 터미널 (토큰을 붙여넣으라는 입력창이 뜬다):
     ```bash
     gh secret set HOMEBREW_TAP_TOKEN -R satanmoo/ebook-capture
     ```

## 매 릴리스

1. 릴리스 전 확인
   ```bash
   swift test
   scripts/e2e.sh preview
   scripts/e2e.sh app 1
   scripts/e2e.sh app 2
   ```
2. 릴리스 시작. 셋 중 하나로 한다. 버전은 `1.2.3` 형식이다.
   - 웹: Actions → **release** → **Run workflow** → version에 `1.2.3` 입력
   - 터미널:
     ```bash
     gh workflow run release -R satanmoo/ebook-capture -f version=1.2.3
     ```
   - 태그 푸시: `git tag v1.2.3 && git push origin v1.2.3`
3. 워크플로가 자동으로 하는 일
   - **release** job: 버전 형식 확인, 같은 버전이 이미 있으면 중단 → `swift test` → `Sources/EbookCapture/Version.swift`에 버전 기록 후 공용 실행 파일 빌드(`--version`이 입력한 버전인지 확인) → `ebook-capture-v1.2.3-macos.tar.gz`, `checksums.txt`를 담은 GitHub Release `v1.2.3` 생성 (버튼으로 시작했다면 이때 태그도 만들어진다)
   - **update-tap** job: [packaging/homebrew/ebook-capture.rb](../packaging/homebrew/ebook-capture.rb) 템플릿에 버전과 sha256을 채워 `satanmoo/homebrew-tap`의 `Formula/ebook-capture.rb`로 커밋
4. 확인
   ```bash
   brew update && brew upgrade ebook-capture   # 처음이면 brew install satanmoo/tap/ebook-capture
   ebook-capture --version
   ```

버전 번호는 코드에 적어 두지 않는다. 저장소의 `Version.swift`는 `dev`이고, 릴리스 빌드에서만 워크플로가 덮어쓴다.

## 실패했을 때

- **`release v1.2.3 already exists`**: 이미 나간 버전이다. 새 버전 번호로 다시 실행한다.
- **`version must look like 1.2.3`**: `v`를 붙이거나(`v1.2.3`) 자리가 모자란(`1.2`) 경우다.
- **`swift test` 실패**: 릴리스는 만들어지지 않는다. 고친 뒤 다시 실행한다.
- **update-tap 실패** (`HOMEBREW_TAP_TOKEN is not set`, 권한 오류, 토큰 만료): GitHub Release는 이미 만들어져 있다. 토큰을 등록하거나 새로 만든 뒤, 실패한 실행 화면에서 **Re-run failed jobs**를 누르면 update-tap만 다시 돈다.

## 참고

- 실행 파일은 ad-hoc 서명만 되어 있다. Homebrew로 받은 파일에는 격리(quarantine) 속성이 붙지 않아 공증 없이 실행된다. 브라우저로 직접 받은 경우에는 `xattr -d com.apple.quarantine ebook-capture`가 필요하다.
- 접근성·화면 기록 권한은 실행 파일이 아니라 사용자의 터미널 앱에 주는 것이라, 업데이트해도 다시 허용할 필요가 없다.
