# 미리알림 날짜

Apple Reminders(미리 알림)의 마감 날짜를 한 창에서 빠르게 바꾸는 macOS 앱이다.
Reminders 앱에서 날짜를 고르려면 항목마다 정보 패널을 열고, 날짜와 시간을 켜고,
작은 달력과 시간 휠을 돌려야 한다. `미리알림 날짜.app`은 여러 항목을 골라
한 번의 클릭, 달력의 날짜, 시간 버튼, 또는 "내일 3시" 같은 한국어 입력으로
옮긴다.

A native macOS app (SwiftUI + EventKit) for moving Apple Reminders due dates
quickly: select one or many reminders, then use a one-click preset, a calendar
day, a time chip, or Korean natural-language input. It runs entirely on the Mac
and makes no network requests.

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
번에 저장되고 `되돌리기`로 원래 날짜, 시작일, 알림까지 돌린다. 제목과 날짜는 이
Mac 밖으로 나가지 않는다.

## Google Tasks와 함께 쓰기

이 앱은 Reminders만 있으면 혼자 동작한다.
[reminders-task-bridge](https://github.com/syncweave-labs/reminders-task-bridge)로
Reminders와 Google Tasks를 동기화하고 있다면, 이 앱에서 바꾼 날짜도 평소처럼
Google Tasks에 날짜로 반영된다(Google Tasks는 시간을 저장하지 않는다).

## 요구 사항

- macOS 14 이상
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
`~/Applications/미리알림 날짜.app`을 지운다. 앱은 자기 데이터를 따로 저장하지
않는다.

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
