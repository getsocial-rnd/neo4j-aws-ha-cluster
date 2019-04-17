COMMIT=$(shell git rev-parse HEAD)
DATE=$(shell date +%Y-%m-%d-%H-%M)

.PHONY:
build:
	@ echo "Building image..."
	@ docker build -t neo .

# Use param NEO_ECR_REPO, e.g. NEO_ECR_REPO=xxxxxxxxxxxx.dkr.ecr.us-east-1.amazonaws.com/neo to specify ECR repository
# Use param NEO_AWS_REGION, e.g. NEO_AWS_REGION=us-east-1
.PHONY:
push_image: build
	@ echo "Pushing image based on last commit $(COMMIT)"
	@ $(shell aws ecr get-login --region $(NEO_AWS_REGION) --no-include-email)
	@ docker tag neo:latest $(NEO_ECR_REPO):$(COMMIT)
	@ docker push $(NEO_ECR_REPO):$(COMMIT)
	@ echo "Pushed image $(NEO_ECR_REPO):$(COMMIT)"