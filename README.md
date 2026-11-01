# 대학 합격·불합격 현황 (Vercel 배포용)

## 구조
- `public/index.html` : 화면 (정적)
- `api/index.js` : 서버리스 API (모든 `/api/*` 요청 처리)
- 저장소: Upstash Redis (Vercel Marketplace에서 연결)

## 배포 순서
1. 이 `vercel-app` 폴더를 GitHub 저장소로 올립니다 (또는 `vercel` CLI 사용).
2. Vercel에서 **Add New → Project**로 해당 저장소를 가져옵니다. Framework는 "Other".
3. 프로젝트 **Storage** 탭 → **Upstash Redis** 생성 후 프로젝트에 연결합니다.
   (`KV_REST_API_URL`, `KV_REST_API_TOKEN` 환경변수가 자동 추가됩니다.)
4. **Settings → Environment Variables**에 추가:
   - `ADMIN_PASSWORD` : 관리자 최초 비밀번호 (6자 이상)
   - `SESSION_SECRET` : 길고 무작위인 문자열 (예: 40자 이상)
5. **Redeploy** 합니다.

## 사용
관리자로 로그인 → 반 추가·담임 비밀번호 설정 → (권장) 열람 코드 설정.
관리자 비밀번호를 화면에서 바꾸면 이후에는 DB에 저장된 값이 우선합니다.

## 주의
- 학생 개인정보이므로 **열람 코드 설정을 권장**합니다.
- 데이터는 Redis 한 키에 저장됩니다. 학교 규모에는 충분하지만, 완전히 동시에 저장하면 마지막 저장이 우선됩니다.
