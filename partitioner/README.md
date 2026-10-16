# Partitioner

## Deployment:

Retrieve an authentication token and authenticate your Docker client to your registry. Use the AWS CLI:

```bash
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws/w4h7v9o3
```

Note: If you receive an error using the AWS CLI, make sure that you have the latest version of the AWS CLI and Docker installed.

Build your Docker image using the following command. For information on building a Docker file from scratch see the instructions here . You can skip this step if your image is already built:

```bash
docker build -t concord-consortium/report-service-partitioner .
```

After the build completes, tag your image so you can push the image to this repository:

```bash
docker tag concord-consortium/report-service-partitioner:latest public.ecr.aws/w4h7v9o3/concord-consortium/report-service-partitioner:TAG
```

where `TAG` is your version, like `1.0.0`

Run the following command to push this image to your newly created AWS repository:

```bash
docker push public.ecr.aws/w4h7v9o3/concord-consortium/report-service-partitioner:TAG
```

### Stack parameters

`TaskSize` sets the job's Fargate vCPU and memory as one choice, so only valid pairs can be picked. It offers every valid pair up to 2 vCPU, the compute environment's `MaxvCpus`, named like `0.25vCPU-512MB` or `1vCPU-8GB`. The default, `0.25vCPU-2GB`, is what production uses; QA uses `0.25vCPU-512MB`, which its log volume fits. Raise production only if jobs fail with `OutOfMemoryError`. A stack created before this parameter existed gets the default on its next update unless `TaskSize` is set.

### QA

- Using the "AdminConcordQA" account, update the `report-service-partitioner-qa` stack using the `public.ecr.aws/w4h7v9o3/concord-consortium/report-service-partitioner:TAG` as the "ContainerImageUri" parameter.

## Production

- Using your normal account, update the `report-service-partitioner` stack using the `public.ecr.aws/w4h7v9o3/concord-consortium/report-service-partitioner:TAG` as the "ContainerImageUri" parameter.
