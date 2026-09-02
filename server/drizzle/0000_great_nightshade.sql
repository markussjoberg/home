CREATE TABLE "public_spots" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"latitude" double precision NOT NULL,
	"longitude" double precision NOT NULL,
	"water_type" text NOT NULL,
	"sports" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"good_directions" jsonb,
	"min_wind" double precision,
	"max_wind" double precision,
	"owner_hash" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "spot_comments" (
	"id" text PRIMARY KEY NOT NULL,
	"spot_id" text NOT NULL,
	"author" text NOT NULL,
	"text" text NOT NULL,
	"wind_ms" double precision,
	"wind_dir" integer,
	"created_at" timestamp with time zone NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "spot_revisions" (
	"id" serial PRIMARY KEY NOT NULL,
	"spot_id" text NOT NULL,
	"editor_hash" text NOT NULL,
	"data" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
