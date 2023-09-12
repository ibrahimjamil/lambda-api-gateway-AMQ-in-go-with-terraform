buildGO:
	cd ./helloGo/ && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 cd ./helloGo/ && go build -o ./bootstrap main.go

dep:
	cd ./terraform && terraform apply -auto-approve && cd ../

destroy:
	cd terraform && terraform destroy --auto-approve && cd ../

# build: cd ./helloGo/ && GOOS=linux GOARCH=amd64 CGO_ENABLED=0  go build -o ./bootstrap main.go
# from command line if exec arch issue.