-- KwachaLink additional setup helper
-- Run in Supabase SQL Editor only after reviewing. Does not delete existing data.
-- Creates a profile automatically after signup.
create or replace function public.handle_new_kwachalink_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name, email, phone, country, bio)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(coalesce(new.email,''),'@',1)),
    new.email,
    new.raw_user_meta_data ->> 'phone',
    coalesce(new.raw_user_meta_data ->> 'country','Malawi'),
    new.raw_user_meta_data ->> 'bio'
  ) on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created_kwachalink on auth.users;
create trigger on_auth_user_created_kwachalink after insert on auth.users
for each row execute procedure public.handle_new_kwachalink_user();

-- Replace same-named policies if they already exist, then add least-privilege policies.
drop policy if exists "Members create own profile" on public.profiles;
create policy "Members create own profile" on public.profiles for insert to authenticated with check (auth.uid() = id);

drop policy if exists "Members view active offers or own offers" on public.offers;
create policy "Members view active offers or own offers" on public.offers for select to authenticated using (status = 'active' or auth.uid() = user_id);

drop policy if exists "Members create own connections" on public.connections;
create policy "Members create own connections" on public.connections for insert to authenticated with check (auth.uid() = requester_id and requester_id <> offer_owner_id and exists (select 1 from public.offers o where o.id = offer_id and o.user_id = offer_owner_id and o.status = 'active'));

drop policy if exists "Offer owners update connection status" on public.connections;
create policy "Offer owners update connection status" on public.connections for update to authenticated using (auth.uid() = offer_owner_id) with check (auth.uid() = offer_owner_id);

drop policy if exists "Participants create deals" on public.deals;
create policy "Participants create deals" on public.deals for insert to authenticated with check (exists (select 1 from public.connections c where c.id = connection_id and (c.requester_id = auth.uid() or c.offer_owner_id = auth.uid()) and c.status = 'accepted'));

drop policy if exists "Participants update deals" on public.deals;
create policy "Participants update deals" on public.deals for update to authenticated using (exists (select 1 from public.connections c where c.id = connection_id and (c.requester_id = auth.uid() or c.offer_owner_id = auth.uid())));

drop policy if exists "Participants create reviews" on public.reviews;
create policy "Participants create reviews" on public.reviews for insert to authenticated with check (auth.uid() = reviewer_id and exists (select 1 from public.deals d join public.connections c on c.id = d.connection_id where d.id = deal_id and d.status = 'completed' and (c.requester_id = auth.uid() or c.offer_owner_id = auth.uid())));

-- NOTE: Before public launch, review all existing policies, payment verification, and legal/compliance obligations.
