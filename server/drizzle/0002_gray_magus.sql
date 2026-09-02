CREATE TABLE "reports" (
	"id" serial PRIMARY KEY NOT NULL,
	"target_type" text NOT NULL,
	"target_id" text NOT NULL,
	"reporter_hash" text NOT NULL,
	"reporter_user_id" text,
	"reason" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"resolved_at" timestamp with time zone,
	"resolution" text
);
--> statement-breakpoint
CREATE TABLE "spot_deletion_proposals" (
	"id" serial PRIMARY KEY NOT NULL,
	"spot_id" text NOT NULL,
	"proposer_hash" text NOT NULL,
	"proposer_user_id" text,
	"created_at" timestamp with time zone NOT NULL,
	"decides_at" timestamp with time zone NOT NULL,
	"status" text DEFAULT 'open' NOT NULL,
	"objected_by" text,
	"resolved_at" timestamp with time zone
);
