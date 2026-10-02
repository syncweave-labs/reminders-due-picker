# 미리알림 날짜

Apple Reminders(미리 알림)의 마감 날짜를 한 창에서 빠르게 바꾸는 macOS 앱이다.
Reminders 앱에서 날짜를 고르려면 항목마다 정보 패널을 열고, 날짜와 시간을 켜고,
작은 달력과 시간 휠을 돌려야 한다. `미리알림 날짜.app`은 여러 항목을 골라
한 번의 클릭, 달력의 날짜, 시간 버튼, 또는 "내일 3시" 같은 한국어 입력으로
옮긴다.

A native macOS app (SwiftUI + EventKit) for moving Apple Reminders due dates
quickly: select one or many reminders, then use a one-click preset, a calendar
day, a time chip, or Korean natural-language input. Date editing runs on the Mac. Optional built-in Google Tasks sync keeps the
connected account in sync without a separate command or standalone scheduler.

- License: [MIT](LICENSE)
- Security policy: [SECURITY.md](SECURITY.md)
- Supported source branch: `main`

## 기능

- 왼쪽은 스마트 목록(전체·오늘·지연됨·날짜 있음·날짜 없음)과 Reminders 목록,
  가운데는 지연됨/오늘/내일/7일 이내/나중에/날짜 없음으로 묶인 미완료 미리
  알림이다. ⌘-클릭·⇧-클릭으로 여러 개를 고를 수 있다. 검색이나 스마트 목록 때문에
  지금 보이지 않는 항목은 선택돼 있어도 바꾸지 않는다.
- 오른쪽 날짜 패널에서 `오늘`, `내일`, `모레`, `이번 주말`, `다음 주 월요일`,
  `하루 당기기/미루기`, `일주일 미루기`, `날짜 없음`을 한 번에 누르거나, 달력의
  날짜를 누르거나, `종일`·`오전 9:00`·`정오`·`오후 3:00`처럼 시간만 바꾼다.
  날짜만 바꾸면 각자의 시간이, 시간만 바꾸면 각자의 날짜가 그대로 남는다.
  달력의 점은 그날 마감인 미리 알림 수다.
- `말로 입력` 칸은 `내일`, `모레 오후 3시`, `다음 주 금`, `10/15`, `15일`,
  `3일 후`, `2시간 뒤`, `+1`(각자 하루 미루기), `종일`, `없음`을 알아듣고,
  Enter 전에 결과 날짜를 미리 보여 준다. 아래쪽 입력줄은 같은 방식으로 날짜를
  넣어 새 미리 알림을 만든다.
- 단축키: ⌘1 오늘, ⌘2 내일, ⌘3 모레, ⌘4 이번 주말, ⌘5 다음 주 월요일,
  ⌘[ / ⌘] 하루 당기기/미루기, ⇧⌘] 일주일 미루기, ⌘0 날짜 없음, ⌘L 말로 입력,
  ⌘N 새 미리 알림, ⌘R 새로 고침, ⌘Z 마지막 날짜 변경 되돌리기(글자를 입력하는
  중에는 입력 되돌리기). 목록에서 오른쪽 클릭해도 같은 날짜 메뉴가 나온다.

## 바꾸는 것과 바꾸지 않는 것

바꾸는 것은 마감 날짜뿐이다. 제목, 메모, 목록, 우선순위, 반복 규칙은 건드리지
않는다. Reminders가 "마감 시각에 알림"을 마감 시각과 같은 시각 알림으로 저장하기
때문에, 그 알림은 날짜와 함께 옮기고 시간을 없애면(종일) 지운다. 종일 항목에
시간을 정하면 Reminders 앱처럼 그 시각 알림을 만든다. 그 밖의 알림(몇 분 전,
위치, 다른 시각)은 그대로 둔다. 마감일을 따라가던 시작일은 함께 옮기고, 새
마감보다 늦어지는 시작일은 마감으로 당긴다.

반복 미리 알림은 날짜를 없앨 수 없고 읽기 전용 목록은 건너뛴다. 목록을 불러온 뒤
다른 기기나 동기화가 먼저 바꾼 항목은 덮어쓰지 않고 그대로 둔다. 모든 변경은 한
번에 저장되고 `되돌리기`로 원래 날짜, 시작일, 알림까지 돌린다. 날짜 편집 자체는 로컬에서 동작한다. Google Tasks를 연결하면 제목·메모·날짜·완료
상태가 연결한 Google 계정과 동기화된다.

## 앱 안에서 Google Tasks 연결

상단의 **Google Tasks** 버튼에서 연결 상태와 마지막 동기화 시간을 확인하고,
**Google 연결/다시 로그인**, **연결 확인**, **지금 동기화**를 실행한다.
처음 연결하는 Mac에서는 Google Cloud Desktop OAuth 클라이언트 JSON을 선택한 뒤
브라우저에서 로그인한다. 계정에 기존 동기화 상태가 있으면 같은 Google 계정임을
확인한 경우에만 새 인증을 저장한다. 다른 계정의 상태는 재사용하지 않는다.

자동 동기화를 켜면 60초마다 미리알림과 Google Tasks의 제목·메모·날짜·완료 상태를
양방향으로 동기화한다. Google Tasks는 시간을 저장하지 않는다. 기존 설치를
이전할 때는 목록 정책과 실행 간격을 그대로 이어받는다. 창을 닫으면 메뉴 막대에서
계속 실행되고, 앱을 종료하면 중단된다. 다음 로그인에는 설치된 앱이 창 없이
실행된다. 자동 동기화를 끄면 현재 작업과 로그인 시 자동 실행이 모두 중지된다.

동기화 엔진은 서명된 앱 번들 안에 포함된다. 독립 command나 별도 Python 스크립트
설치는 필요 없다. Python 3.10 이상 런타임은 필요하다. 미리알림 읽기·쓰기는 같은
앱 실행 파일의 EventKit 모드로 처리해 앱의 접근 권한을 공유한다.

설정·OAuth 인증·동기화 매핑·상태·비공개 로그는
`~/Library/Application Support/RemindersDuePicker/GoogleSync`에 저장한다(디렉터리
0700, 파일 0600). 대량 삭제·완료는 기존 엔진의 확인 창에서 승인한 작업만
반영하며, 승인 대기 중에도 나머지 변경은 계속 동기화한다. 처음 연결한 Mac은
삭제 전파를 끈 상태로 시작한다.

기존 `icloud-reminders-google-sync` 설치가 있으면 설치기가 별도 LaunchAgent를
중지하고 현재 인증·매핑을 그대로 이전한다. 기존 자료는 새 앱에서 날짜/제목
일치 검증을 포함한 동기화가 성공할 때까지 보존한다. 성공 후 검토된 main에서:

```bash
python3 scripts/migrate-google-sync.py cleanup
```

이 명령은 이전 command 바로가기, LaunchAgent, 실행용 릴리스, 설정·이전 백업·로그를
제거한다. 개발 소스 저장소는 삭제하지 않는다. 새 앱의 인증과 상태 기록은 유지한다.

## 요구 사항

- macOS 14 이상
- Google Tasks 동기화: Python 3.10 이상 (이 Mac의 Homebrew Python 사용)
- Xcode Command Line Tools (`xcode-select --install`). Xcode는 필요 없다.
- 선택: `Apple Development` 또는 `Developer ID Application` 코드 서명 인증서.
  있으면 그것으로 서명해 재설치 후에도 미리 알림 권한이 유지된다. 없으면 ad-hoc
  서명이라 재설치할 때마다 권한을 다시 묻는다.

## 설치

검토·병합된 `main`에서 설치한다. 설치기는 릴리스 소스 게이트
(`scripts/check-release-source.sh`)를 먼저 통과해야 한다. 깨끗한 `main`이고
`HEAD`가 `origin/main`, GitHub의 live `main`, `DEPLOY_EXPECTED_COMMIT`와 모두
같아야 한다. 그다음 앱을 빌드·서명하고, 실행 중인 앱을 닫은 뒤
`~/Applications/미리알림 날짜.app`을 한 번에 교체한다.

```bash
git clone https://github.com/syncweave-labs/reminders-due-picker.git \
  ~/apps/reminders-due-picker
cd ~/apps/reminders-due-picker
git switch main
git pull --ff-only
DEPLOY_EXPECTED_COMMIT="$(git rev-parse HEAD)" bash scripts/install-due-picker-app.sh --reveal
```

설치된 앱은 Finder → 홈 → 응용 프로그램, 또는 Spotlight에서 "미리알림 날짜"로
연다. 설치한 commit은 앱 안의 `Contents/Resources/release-source.txt`에 남는다.
처음 열 때 한 번 미리 알림 접근을 허용한다. 거부했다면 시스템 설정 → 개인정보
보호 및 보안 → 미리 알림에서 `미리알림 날짜`를 켜고 앱의 `다시 확인`을 누른다.

`DEPLOY_GIT_ALLOW_DIRTY`, `DEPLOY_GIT_ALLOW_NON_MAIN`,
`DEPLOY_GIT_ALLOW_UNPUSHED`는 비상용이며 `DEPLOY_GIT_OVERRIDE_REASON`이
필수다. 기대 GitHub origin은 우회할 수 없다.

되돌리려면 이전 `main` commit을 체크아웃해 같은 방식으로 설치하거나
`~/Applications/미리알림 날짜.app`을 지운다. Google Tasks 연결 정보까지 제거하려면 먼저 자동 동기화를 끄고
위의 앱 전용 저장소를 삭제한다. 미리알림과 Google Tasks 항목 자체는 삭제되지 않는다.

## 개발

```text
Sources/DueCore.swift        # 날짜 규칙, 한국어 입력 해석, 알림·시작일 계획 (Foundation만)
Sources/ReminderStore.swift  # EventKit 읽기·저장·되돌리기
Sources/AppModel.swift       # 선택, 필터, 적용, 빠른 추가
Sources/Views.swift          # SwiftUI 창
Sources/App.swift            # 앱 진입점과 메뉴·단축키
Tests/CoreTests/             # 날짜 규칙 테스트 (macOS·Linux)
Tests/AppTests/              # EventKit·앱 모델 테스트 (macOS)
Tools/                       # 아이콘, 데모 데이터, 화면 스냅숏
scripts/                     # 빌드, 테스트, 릴리스 게이트, 설치
```

```bash
bash -n scripts/*.sh
bash scripts/test-release-source-gate.sh
bash scripts/test-due-picker.sh
bash scripts/build-due-picker-app.sh                      # build/ (Git 무시)
bash scripts/build-due-picker-app.sh --snapshots /tmp/due # 데모 데이터로 창 PNG 렌더링
```

테스트는 실제 미리 알림을 읽거나 쓰지 않는다. EventKit 테스트는 저장하지 않는
메모리 속 미리 알림만 고치고, 앱 모델 테스트와 스냅숏은 내장 데모 데이터를 쓴다.
날짜 규칙 테스트는 CI의 Linux에서도, EventKit·앱 모델 테스트와 빌드는 CI의
macOS에서 돈다.
