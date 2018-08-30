COMMIT=$(shell git rev-parse HEAD)

.PHONY:
build:
	@ echo "Building image..."
	@ docker build -t neo .

# Use param REPO, e.g. REPO=xxxxxxxxxxxx.dkr.ecr.us-east-1.amazonaws.com/neo to specify ECR repository
# Use param REGION, e.g. REGION=us-east-1
.PHONY:
push_image: build
	@ echo "Pushing image based on last commit $(COMMIT)"
	@ $(shell aws ecr get-login --region $(NEO_AWS_REGION))
	@ docker tag neo:latest $(NEO_ECR_REPO):$(COMMIT)
	@ docker push $(NEO_ECR_REPO):$(COMMIT)
	@ echo "Pushed image $(NEO_ECR_REPO):$(COMMIT)"
