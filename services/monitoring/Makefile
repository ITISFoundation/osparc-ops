.DEFAULT_GOAL := help



# STACK_NAME defaults to name of the current directory. Should not to be changed if you follow GitOps operating procedures.
STACK_NAME = $(notdir $(CURDIR))
SWARM_HOSTS = $(shell docker node ls --format={{.Hostname}} 2>/dev/null)
TEMP_COMPOSE=.stack.${STACK_NAME}.yaml


# TARGETS --------------------------------------------------
include ../../scripts/common.Makefile

.PHONY: up
up: .init .env ${TEMP_COMPOSE} ## Deploys or updates current stack "$(STACK_NAME)". If MONITORED_NETWORK is not specified, it will create an attachable network
	@docker stack deploy --compose-file ${TEMP_COMPOSE} $(STACK_NAME)

.PHONY: up-letsencrypt
up-letsencrypt: .init ${TEMP_COMPOSE}-letsencrypt .env  ## Deploys or updates current stack "$(STACK_NAME)" using let's encrypt
	@docker stack deploy --compose-file ${TEMP_COMPOSE}-letsencrypt ${STACK_NAME}

.PHONY: up-aws
up-aws: .init ${TEMP_COMPOSE}-aws .env  ## Deploys or updates current stack "$(STACK_NAME)" in AWS
	@docker stack deploy --compose-file ${TEMP_COMPOSE}-aws ${STACK_NAME}

.PHONY: ${TEMP_COMPOSE}
${TEMP_COMPOSE}: docker-compose.yml
	@docker-compose -f $< --log-level=ERROR config > $@

.PHONY: ${TEMP_COMPOSE}-letsencrypt
${TEMP_COMPOSE}-letsencrypt: docker-compose.yml docker-compose.letsencrypt.yml
	@docker-compose -f $< -f docker-compose.letsencrypt.yml --log-level=ERROR config > $@

.PHONY: ${TEMP_COMPOSE}-aws
${TEMP_COMPOSE}-aws: docker-compose.yml docker-compose.aws.yml
	@docker-compose -f $< -f docker-compose.aws.yml --log-level=ERROR config > $@