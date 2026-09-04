CREATE TABLE "push_tokens" (
	"token" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"sandbox" integer DEFAULT 0 NOT NULL,
	"updated_at" timestamp with time zone NOT NULL
);
