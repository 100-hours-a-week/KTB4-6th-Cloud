# V3 배포 설정

Argo CD가 클러스터에 반영하는 매니페스트를 둔다(5단계 8번 배포 설계 3장). Argo CD는 `main` 브랜치의 이 폴더만 본다.

| 폴더 | 내용 | 리뷰 |
| --- | --- | --- |
| `charts/` | 우리 앱 공통 Helm 차트 `meety-app` | 담당 팀 + Cloud |
| `envs/staging/` | `staging` 워크로드별 값 파일 | 검사만 통과하면 자동 머지 |
| `envs/prod/` | `prod` 워크로드별 값 파일 | 담당 팀 |
| `platform/` | Argo CD, LBC, Karpenter, KEDA, ESO 등 외부 애드온 값 파일, Namespace, NodePool | Cloud |

- 비밀값은 여기에 두지 않는다. Parameter Store에 두고 External Secrets Operator로 가져온다(5단계 9번 보안과 격리 설계 6장).
- 폴더 이름은 구축하면서 바뀔 수 있다. 바뀌면 이 표와 `.github/CODEOWNERS`를 함께 고친다.
