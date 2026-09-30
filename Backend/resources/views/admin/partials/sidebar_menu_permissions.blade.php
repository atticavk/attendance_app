@php
    $selectedMenuKeys = collect($selectedMenuKeys ?? [])->map(fn ($key) => trim((string) $key))->filter()->values()->all();
    $selectedMenuKeyMap = array_fill_keys($selectedMenuKeys, true);
@endphp

<style>
    .admin-menu-permission-accordion .accordion-button {
        gap: 0.65rem;
    }

    .admin-menu-permission-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        gap: 0.75rem;
    }

    .admin-menu-permission-grid .form-check {
        border: 1px solid var(--admin-border-color);
        border-radius: 10px;
        padding: 0.65rem 0.75rem 0.65rem 2.35rem;
        background: var(--admin-surface-color);
    }
</style>

<div class="mt-4">
    <div class="d-flex flex-wrap justify-content-between align-items-center gap-2 mb-3">
        <div>
            <h5 class="mb-1">Sidebar Menu Access</h5>
            <p class="mb-0 text-muted">Select the main sidebar options and collapsible items visible to this admin.</p>
        </div>
        <div class="d-flex gap-2">
            <button type="button" class="btn btn-outline-primary btn-sm js-admin-menu-select-all">Select All</button>
            <button type="button" class="btn btn-outline-secondary btn-sm js-admin-menu-clear-all">Clear All</button>
        </div>
    </div>

    <div class="accordion admin-menu-permission-accordion" id="adminMenuPermissionAccordion">
        @foreach ($menuGroups as $groupIndex => $group)
            @php
                $items = $group['items'] ?? [];
                $groupSelectedCount = collect($items)->filter(fn ($item) => isset($selectedMenuKeyMap[$item['key']]))->count();
                $groupIsOpen = $groupSelectedCount > 0 || $groupIndex === 0;
                $groupId = 'adminMenuGroup'.preg_replace('/[^A-Za-z0-9]+/', '', $group['key']);
            @endphp
            <div class="accordion-item">
                <h2 class="accordion-header" id="{{ $groupId }}Heading">
                    <button class="accordion-button {{ $groupIsOpen ? '' : 'collapsed' }}" type="button"
                        data-bs-toggle="collapse" data-bs-target="#{{ $groupId }}Body"
                        aria-expanded="{{ $groupIsOpen ? 'true' : 'false' }}" aria-controls="{{ $groupId }}Body">
                        <input class="form-check-input mt-0 js-admin-menu-group" type="checkbox"
                            data-group="{{ $group['key'] }}"
                            @checked($groupSelectedCount > 0 && $groupSelectedCount === count($items))
                            onclick="event.stopPropagation();">
                        <span class="fw-semibold">{{ $group['label'] }}</span>
                        <span class="badge bg-primary-subtle text-primary">{{ $groupSelectedCount }}/{{ count($items) }}</span>
                    </button>
                </h2>
                <div id="{{ $groupId }}Body" class="accordion-collapse collapse {{ $groupIsOpen ? 'show' : '' }}"
                    aria-labelledby="{{ $groupId }}Heading" data-bs-parent="#adminMenuPermissionAccordion">
                    <div class="accordion-body">
                        <div class="admin-menu-permission-grid">
                            @foreach ($items as $item)
                                <label class="form-check mb-0">
                                    <input class="form-check-input js-admin-menu-item" type="checkbox"
                                        name="sidebar_menu_permissions[]" value="{{ $item['key'] }}"
                                        data-group="{{ $group['key'] }}"
                                        @checked(isset($selectedMenuKeyMap[$item['key']]))>
                                    <span class="form-check-label">{{ $item['label'] }}</span>
                                </label>
                            @endforeach
                        </div>
                    </div>
                </div>
            </div>
        @endforeach
    </div>
</div>

@once
    <script>
        document.addEventListener('DOMContentLoaded', function () {
            const roleSelect = document.querySelector('select[name="role"]');
            const accountBlockedKeys = new Set([
                'outsource.employee_create',
                'outsource.employee_index',
            ]);

            function applyRoleRestrictions() {
                const role = (roleSelect?.value || '').trim().toLowerCase();
                document.querySelectorAll('.js-admin-menu-item').forEach(item => {
                    const blockedForAccounts = role === 'accounts' && accountBlockedKeys.has(item.value);
                    item.disabled = blockedForAccounts;
                    if (blockedForAccounts) {
                        item.checked = false;
                    }
                    item.closest('.form-check')?.classList.toggle('opacity-50', blockedForAccounts);
                });
            }

            function refreshAdminMenuGroups() {
                applyRoleRestrictions();
                document.querySelectorAll('.js-admin-menu-group').forEach(groupCheckbox => {
                    const group = groupCheckbox.dataset.group || '';
                    const items = Array.from(document.querySelectorAll(`.js-admin-menu-item[data-group="${group}"]:not(:disabled)`));
                    const checked = items.filter(item => item.checked).length;
                    groupCheckbox.checked = items.length > 0 && checked === items.length;
                    groupCheckbox.indeterminate = checked > 0 && checked < items.length;
                    const badge = groupCheckbox.closest('.accordion-button')?.querySelector('.badge');
                    if (badge) {
                        badge.textContent = `${checked}/${items.length}`;
                    }
                });
            }

            document.addEventListener('change', function (event) {
                if (event.target === roleSelect) {
                    refreshAdminMenuGroups();
                    return;
                }

                const groupCheckbox = event.target.closest('.js-admin-menu-group');
                if (groupCheckbox) {
                    const group = groupCheckbox.dataset.group || '';
                    document.querySelectorAll(`.js-admin-menu-item[data-group="${group}"]:not(:disabled)`).forEach(item => {
                        item.checked = groupCheckbox.checked;
                    });
                    refreshAdminMenuGroups();
                    return;
                }

                if (event.target.closest('.js-admin-menu-item')) {
                    refreshAdminMenuGroups();
                }
            });

            document.querySelector('.js-admin-menu-select-all')?.addEventListener('click', function () {
                document.querySelectorAll('.js-admin-menu-item:not(:disabled)').forEach(item => item.checked = true);
                refreshAdminMenuGroups();
            });

            document.querySelector('.js-admin-menu-clear-all')?.addEventListener('click', function () {
                document.querySelectorAll('.js-admin-menu-item').forEach(item => item.checked = false);
                refreshAdminMenuGroups();
            });

            refreshAdminMenuGroups();
        });
    </script>
@endonce
