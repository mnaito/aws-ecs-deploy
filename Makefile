#####
# Dockerコンテナ化されたアプリをAmazon ECSへデプロイするときに用いるコマンドセットと依存関係を記述する
#####

### Repository names
ENV := dev
.PHONY = selfupdate up up-build up-fix down init git_checkout git_pull sync build dist deploy

include makefile.${ENV}

_LATEST_RECOMMENDED := 1

###
# NOT configurable stuffs
#
ECR_REPOSITORY_URL   = ${1}.dkr.ecr.${AWS_REGION}.amazonaws.com/${2}
TIMESTAMP := $(shell date '+%Y%m%d-%H%M')

###
# Rules
#

### 自身を最新化
selfupdate: 
	git pull origin master

### docker-compose
up: selfupdate _check-repos
	docker-compose up
up-build: selfupdate _check-repos
	docker-compose up --build
up-fix: selfupdate down _check-repos
	yes | docker network prune -f
	lsof -i:15432 -Fp | grep -e 'p[0-9]*' | sed -e 's/^p//g' | uniq | xargs kill -9
	docker ps | awk '{print $$1}' | tail -n +2 | xargs docker stop ||:
	docker-compose up --build --force-recreate
down:
	docker-compose down

_check-repos:
	for r in mms-public-web mms-private-web mms-jweb mms-modules mms-aws; do [ ! -d "../$${r}" ] && (git clone git@github.com:ei-mms/$${r}.git ../$${r} && pushd ../$${r} && git submodule update --init && popd) ||: ;done

### アプリのgit reset
git_reset: $(addprefix git_reset/,$(TARGET))
### アプリのgit checkout
git_checkout: _require_git_branch $(addprefix git_checkout/,$(TARGET))
### アプリのgit pull
git_pull: _require_git_branch $(addprefix git_pull/,$(TARGET))
### アプリ用のDockerfileなどを最新化・同期
sync: $(addprefix sync/,$(TARGET))
### Docker Imageのビルド
build: _check_prerequisites _require_git_branch git_reset git_checkout git_pull $(addprefix tag/,$(TARGET)) $(addprefix build/,$(TARGET))
### ソース最新化 + Docker Imageのビルド + ECR push
dist: _check_prerequisites _require_aws_profile build $(addprefix ecr_push/,$(TARGET))
### コンテナデプロイ
deploy: _check_prerequisites _require_aws_profile _before_deploy $(addprefix tag/,$(TARGET)) $(addprefix deploy/,$(TARGET)) _finalize_deploy stat
###
switch: _check_prerequisites _require_aws_profile
	export AWS_PROFILE="${AWS_PROFILE}"; \
	export ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME}"; \
	export ECS_ALB_LISTENER="${ECS_ALB_LISTENER}"; \
	export ECS_ELB_LISTENERS="${ECS_ELB_LISTENERS}"; \
	export ECS_SERVICE_NAME="${ECS_SERVICE_NAME}"; \
	scripts/switch-listeners.sh

### 問い合わせる
stat: _check_prerequisites _require_aws_profile
	@_tmp=$$(mktemp) && \
	echo && aws --profile ${AWS_PROFILE} ecs describe-task-definition --task-definition $$(aws --profile ${AWS_PROFILE} ecs describe-services --cluster ${ECS_CLUSTER_NAME} --service ${ECS_SERVICE_NAME} | jq -r '.services[0].deployments[0].taskDefinition' | sed -e 's/.*\///g') --output json > $$_tmp && \
	(cat $$_tmp | jq -r '.taskDefinition | "Currently running task revision: "+(.revision|tostring)') && echo ===== && \
	(cat $$_tmp | jq -r '.taskDefinition.containerDefinitions[]|(.image|sub("^[^/]+/";""))') && echo

# Task Definitionを戻す
rollback: _check_prerequisites _require_aws_profile _before_deploy
	$(eval __XXX := $(shell echo '=== Last 20 Task definitions: `${TASK_FAMILY}` ===' 1>&2 && aws --profile ${AWS_PROFILE} ecs list-task-definitions | jq -r '.taskDefinitionArns|reverse|.[]|select(.|test(".*/${TASK_FAMILY}"))' | head -n 20 1>&2 ))	
	$(eval _LATEST_TASK_REVISION := $(shell aws --profile ${AWS_PROFILE} ecs describe-task-definition --task-definition ${TASK_FAMILY} --output json | jq -r '.taskDefinition.revision'))
	$(eval DEPLOY_TASK_REVISION   := $(shell if [ ! -z "${DEPLOY_TASK_REVISION}" ]; then echo "${DEPLOY_TASK_REVISION}";else read -e -p 'task revision for `${TASK_FAMILY}` [latest => ${_LATEST_TASK_REVISION}]: '; ([[ ! -z "$${REPLY}" ]] && echo $${REPLY} || echo ${_LATEST_TASK_REVISION});fi))
	aws --profile ${AWS_PROFILE} ecs update-service --cluster ${ECS_CLUSTER_NAME} --service ${ECS_SERVICE_NAME} --task-definition ${TASK_FAMILY}:${DEPLOY_TASK_REVISION}

### ブランチ名を要求
_require_git_branch: 
	$(eval GIT_BRANCH := $(shell if [ ! -z "${GIT_BRANCH}" ]; then echo "${GIT_BRANCH}";else read -e -p 'git branch/tag [${DEFAULT_GIT_BRANCH}]: '; ([[ ! -z "$${REPLY}" ]] && echo $${REPLY} || echo ${DEFAULT_GIT_BRANCH});fi))

### AWS_PROFILEを要求
_require_aws_profile: 
	$(eval AWS_PROFILE := $(shell if [ ! -z "${AWS_PROFILE}" ]; then echo "${AWS_PROFILE}";else read -e -p 'AWS profile name [${DEFAULT_AWS_PROFILE}]: '; ([[ ! -z "$${REPLY}" ]] && echo $${REPLY} || echo ${DEFAULT_AWS_PROFILE});fi))
	@aws sts --profile ${AWS_PROFILE} get-caller-identity > /dev/null

### checks if prerequisites are satisfied for deployment process...
_check_prerequisites: 
	@(which pip     > /dev/null || (echo '`pip` is required. try `curl https://bootstrap.pypa.io/get-pip.py | sudo python`'; exit 1;))
	@(which aws     > /dev/null || (echo '`awscli` is required. try `pip install awscli`'; exit 1;))
	@(which brew    > /dev/null || (echo '`brew` is required. try `/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)`'; exit 1;))
	@(which jq      > /dev/null || (echo '`jq` is required. try `brew install jq``'; exit 1;))
#	@(python -c "import configparser;" || (echo '`configparser` python module is required. try `pip install configparser`'; exit 1;))
#	@([[ $(echo "$(docker -v | grep -Eo '\d{2}\.\d{2}') >= 18.06" | bc -l) -eq 1 ]] || echo 'Docker version needs 18.06 or above.'; exit 1)
	@echo "You're about to deploy these targets to \"${ENV}\": \"${TARGET}\""



###
# definitions/rules for `sync`
#
define sync_files
	rm -rf ${1}${2}/docker
	rm -rf ${1}${2}/scripts
	rsync -riv template/ ${1}${2}/
	
endef
$(addprefix sync/,${TARGET}):
	$(call sync_files,../,$(notdir $@))

###
# definitions/rules for `git_reset`
#
define git_reset
	cd ${1}${2} && \
	git fetch --prune --all && \
	git reset --hard && \
	git clean -fd && \
	git submodule --quiet foreach --recursive 'git fetch --all --prune && git clean -ffd && git reset --hard'

endef

$(addprefix git_reset/,${TARGET}):
	$(call git_reset,../,$(notdir $@))

###
# definitions/rules for `git_checkout`
# ブランチが存在しないなどのcheckoutエラーは無視
#
define git_checkout
	cd ${1}${2} && \
	(git checkout ${GIT_BRANCH} || git checkout master) && \
	(git submodule --quiet foreach --recursive 'git checkout ${GIT_BRANCH} || git checkout master')

endef
$(addprefix git_checkout/,${TARGET}):
	$(call git_checkout,../,$(notdir $@))


###
# definitions/rules for `git_pull`
# ブランチが存在しないなどのcheckoutエラーは無視
#
define git_pull
	cd ${1}${2} && \
	(git merge origin/${GIT_BRANCH} || (git checkout master && git pull origin master && git checkout ${GIT_BRANCH} || :)) && \
	git submodule --quiet foreach --recursive 'git merge origin/${GIT_BRANCH} || (git checkout master && git pull origin master && git checkout ${GIT_BRANCH} || :)'
	$(eval _LATEST_RECOMMENDED :=)

endef
$(addprefix git_pull/,${TARGET}):
	$(call git_pull,../,$(notdir $@))
	

###
# definitions/rules for `build`
#

### ECRにログインするためのdockerコマンドを生成する
define ecr_login
	$$(aws --profile "${AWS_PROFILE}" ecr get-login --registry-ids "${1}" --no-include-email --region ${AWS_REGION})
endef

### コンテナのビルド
define build_container
	cd ${1}${2} && \
	DOCKER_BUILDKIT=1 docker build -t ${2} .
	
endef

### image tagとしてブランチ名+タイムスタンプを取得し、IMAGE_***_TAGにセット
define get_default_image_tag
	$(eval _DEFAULT_TAG := $(shell if [ ! -z "${_LATEST_RECOMMENDED}" ]; then echo "latest";else cd ${1}${2} && echo $$((git describe --tags --exact-match 2> /dev/null || git symbolic-ref -q --short HEAD || git rev-parse --short HEAD) | sed -e 's/[^A-Za-z0-9_.-]/-/g')-${TIMESTAMP}-$$(git rev-parse --short HEAD); fi))
	
endef

### ECRにDockerイメージをPushする
define push_ecr_image
	cd ${1}${2} && \
	docker tag "${2}:latest" "$(call ECR_REPOSITORY_URL,${3},${2}):${IMAGE_${2}_TAG}" && \
	docker tag "${2}:latest" "$(call ECR_REPOSITORY_URL,${3},${2}):latest" && \
	docker push "$(call ECR_REPOSITORY_URL,${3},${2}):${IMAGE_${2}_TAG}" && \
	docker push "$(call ECR_REPOSITORY_URL,${3},${2}):latest"

	docker images | grep '.dkr.ecr.ap-northeast-1.amazonaws.com' | awk '{print $3}' | uniq | xargs docker rmi > /dev/null 2>&1 || :

endef


### 
# 各アプリのビルドルール
# プロジェクトに依ってECR pushを行うAWSアカウントが異なることを想定する
###
### tag - tagging
$(addprefix tag/,${TARGET}):
	$(call get_deploy_image_tag,../,$(notdir $@))

### build - docker build
$(addprefix build/,${TARGET}):
	$(call build_container,../,$(notdir $@))

### ecr_push - pushing an image to ECR
$(addprefix ecr_push/,${TARGET}):
	$(call ecr_login,${ECR_ACCOUNT_ID})
	$(call push_ecr_image,../,$(notdir $@),${ECR_ACCOUNT_ID})

###
# definitions/rules for `deploy`
#
### ECS Service/TaskDefinitionの更新に使用するIMAGE_TAGを得る
### 無ければプロンプト
define get_deploy_image_tag
	$(eval __XXX := $(shell [[ "1" == "${_LATEST_RECOMMENDED}" && ! -z "${AWS_PROFILE}" ]] && echo '=== Last 20 ECR images for `${2}` ===' 1>&2 && aws --profile ${AWS_PROFILE} ecr describe-images --repository-name ${2} | jq -r '.imageDetails|sort_by(.imagePushedAt)|reverse|.[]|select(.imageTags != null)|.imageTags[]' | head -n 20 1>&2 ))
	$(call get_default_image_tag,${1},${2})
	$(eval IMAGE_${2}_TAG := $(shell if [ ! -z "${IMAGE_${2}_TAG}" ]; then echo "${IMAGE_${2}_TAG}";else read -e -p 'ECR image tag for `${2}` [${_DEFAULT_TAG}]: '; ([[ ! -z "$${REPLY}" ]] && echo $${REPLY} || echo ${_DEFAULT_TAG});fi))

endef

_before_deploy: _check_prerequisites _require_aws_profile
	$(eval ECS_SERVICE_NAME := $(shell export AWS_PROFILE="${AWS_PROFILE}"; export ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME}"; export ECS_BLUE_SERVICE_NAME="${ECS_BLUE_SERVICE_NAME}"; export ECS_GREEN_SERVICE_NAME="${ECS_GREEN_SERVICE_NAME}"; export ECS_ALB_LISTENER="${ECS_ALB_LISTENER}"; export ECS_ELB_LISTENERS="${ECS_ELB_LISTENERS}"; export ECS_SERVICE_NAME="${ECS_SERVICE_NAME}"; scripts/find-ecs-service.sh))

_create_working_task_def:
	$(eval WORKING_TASK_DEF_FILE := $(shell mktemp))
	aws --profile ${AWS_PROFILE} ecs describe-task-definition --task-definition ${TASK_FAMILY} --output json > ${WORKING_TASK_DEF_FILE}

_remove_working_task_def:
	rm -f ${WORKING_TASK_DEF_FILE}


### ECS Serviceの更新を行う
define update_ecs_service
	$(eval _CLUSTER_NAME   := ${1})
	$(eval _SERVICE_NAME   := ${2})
	$(eval _TASK_FAMILY    := ${3})
	aws --profile ${AWS_PROFILE} ecs update-service --cluster ${_CLUSTER_NAME} --service ${_SERVICE_NAME} --task-definition ${_TASK_FAMILY}

endef

### ECS Task Definitionの更新を行う
define update_ecs_taskdefinition
	$(eval _TASK_FAMILY    := ${1})
	secondtmp=$$(mktemp) && \
	cat ${WORKING_TASK_DEF_FILE} | jq '.taskDefinition|{networkMode: .networkMode, family: .family, volumes: .volumes, containerDefinitions: .containerDefinitions}' > $$secondtmp && \
	aws --profile ${AWS_PROFILE} ecs register-task-definition --family ${_TASK_FAMILY} --cli-input-json file://$$secondtmp
	rm -f $$secondtmp

endef

### ECS Task Definition のJSON中の `image` 部分を置換
define update_working_ecs_taskdefinition
	$(eval _CONTAINER_NAME := ${1})
	$(eval _NEW_IMAGE_NAME := ${2})

	secondtmp=$$(mktemp) && \
	cat ${WORKING_TASK_DEF_FILE} | \
	jq -r --arg NDI ${_NEW_IMAGE_NAME} '(.taskDefinition.containerDefinitions[] | select(.name == "${_CONTAINER_NAME}")) .image |= $$NDI' > $$secondtmp && \
	mv $$secondtmp ${WORKING_TASK_DEF_FILE}

endef


### 
# 各アプリのデプロイルール
###

### deploy -
$(addprefix deploy/,${TARGET}): _create_working_task_def
	$(call update_working_ecs_taskdefinition,$(notdir $@),$(call ECR_REPOSITORY_URL,${ECR_ACCOUNT_ID},$(notdir $@)):${IMAGE_$(notdir $@)_TAG})

### finalize - 
_finalize_deploy:
	$(call update_ecs_taskdefinition,${TASK_FAMILY})
	$(call update_ecs_service,${ECS_CLUSTER_NAME},${ECS_SERVICE_NAME},${TASK_FAMILY})

