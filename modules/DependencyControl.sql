BEGIN TRANSACTION;
CREATE TABLE "UpdateChecks" (
	`Namespace`	TEXT,
	`Time`	INTEGER NOT NULL,
	`TotalCount`	INTEGER NOT NULL,
	PRIMARY KEY(Namespace)
);
CREATE TABLE "InstalledPackages" (
	`Namespace`	TEXT NOT NULL UNIQUE,
	`Name`	TEXT,
	`Version`	INTEGER NOT NULL,
	`ScriptType`	INTEGER NOT NULL,
	`RecordType`	INTEGER NOT NULL,
	`ActiveChannel`	TEXT,
	`Author`	TEXT,
	`Description`	TEXT,
	`WebURL`	TEXT,
	`FeedURL`	TEXT,
	`InstallState`	INTEGER NOT NULL,
	`Timestamp`	INTEGER NOT NULL,
	PRIMARY KEY(Namespace)
);
COMMIT;
