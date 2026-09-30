# App-specific R8 rules belong here. Flutter plugins supply their own consumer
# rules, so keep this file intentionally minimal to preserve full optimization.

# Room loads generated database implementations by name and invokes their
# zero-argument constructors reflectively. AGP 9/R8 can otherwise optimize the
# WorkManager database constructor away even though Room keeps the class name.
-keepclassmembers class * extends androidx.room.RoomDatabase {
    <init>();
}
