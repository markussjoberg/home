CREATE TABLE "user_alerts" (
	"user_id" text NOT NULL,
	"alert_id" text NOT NULL,
	"data" jsonb NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	CONSTRAINT "user_alerts_user_id_alert_id_pk" PRIMARY KEY("user_id","alert_id")
);
--> statement-breakpoint
CREATE TABLE "user_spots" (
	"user_id" text NOT NULL,
	"spot_id" text NOT NULL,
	"data" jsonb NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	CONSTRAINT "user_spots_user_id_spot_id_pk" PRIMARY KEY("user_id","spot_id")
);
--> statement-breakpoint
ALTER TABLE "notifications" ADD COLUMN "dedup_key" text;