# Databricks notebook source
# Prints the identity the job runs as, so you can see run_as is the job SP and not the deployer.
who = spark.sql("select current_user()").first()[0]
print(f"oidc-demo-etl running as: {who}")
print("rows:", spark.range(1000).count())
