/*
KWACHALINK — CONSOLIDATED BACKEND MIGRATION
Supabase project: pzcudjyjfohlrwkefkhb
First administrator: msukwainno@gmail.com

Run in Supabase SQL Editor.
This migration is additive: it preserves existing tables and records.

IMPORTANT:
- The Auth account for msukwainno@gmail.com must already exist.
- It must have a corresponding public.profiles row.
- Never put the Supabase service_role key in Bolt/browser code.
*/

BEGIN;

-- 1. Add buyer/seller identity to deals while preserving existing rows.
ALTER TABLE public.deals
    ADD COLUMN IF NOT EXISTS buyer_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS seller_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS deals_buyer_id_idx ON public.deals(buyer_id);
CREATE INDEX IF NOT EXISTS deals_seller_id_idx ON public.deals(seller_id);

-- 2. Role helper functions.
CREATE OR REPLACE FUNCTION public.is_kwachalink_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    );
$$;

CREATE OR REPLACE FUNCTION public.is_kwachalink_moderator()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.user_roles ur
        WHERE ur.user_id = auth.uid()
          AND ur.role IN ('admin', 'moderator')
    );
$$;

REVOKE ALL ON FUNCTION public.is_kwachalink_admin() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_kwachalink_moderator() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_kwachalink_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_kwachalink_moderator() TO authenticated;

-- 3. Protect profile verification status. Admin changes go through RPC.
CREATE OR REPLACE FUNCTION public.protect_profile_fields()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
        IF COALESCE(current_setting('request.jwt.claim.role', true), '') <> 'service_role'
           AND NOT EXISTS (
               SELECT 1 FROM public.user_roles ur
               WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
           )
        THEN
            RAISE EXCEPTION 'Only an administrator can change verification status';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- Existing protect_profile_fields_trigger remains attached to this function.

-- 4. Deal proposal, confirmation and dispute workflows.
CREATE OR REPLACE FUNCTION public.create_deal(
    p_connection_id uuid,
    p_buyer_id uuid,
    p_seller_id uuid,
    p_amount numeric,
    p_currency text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_requester_id uuid;
    v_owner_id uuid;
    v_deal_id uuid;
    v_currency text := upper(trim(p_currency));
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Deal amount must be greater than zero';
    END IF;
    IF p_buyer_id IS NULL OR p_seller_id IS NULL OR p_buyer_id = p_seller_id THEN
        RAISE EXCEPTION 'A deal must have two different participants';
    END IF;

    SELECT c.requester_id, c.offer_owner_id
    INTO v_requester_id, v_owner_id
    FROM public.connections c
    WHERE c.id = p_connection_id
      AND c.status = 'accepted'
      AND (c.requester_id = v_user_id OR c.offer_owner_id = v_user_id)
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'An accepted connection involving you is required';
    END IF;

    IF NOT (
        (p_buyer_id = v_requester_id AND p_seller_id = v_owner_id)
        OR (p_buyer_id = v_owner_id AND p_seller_id = v_requester_id)
    ) THEN
        RAISE EXCEPTION 'Buyer and seller must be the connection participants';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.supported_currencies sc
        WHERE sc.code = v_currency AND sc.is_active = true
    ) THEN
        RAISE EXCEPTION 'Currency is not currently supported';
    END IF;

    INSERT INTO public.deals(
        connection_id, buyer_id, seller_id, amount, currency,
        status, buyer_confirmed, seller_confirmed
    )
    VALUES (
        p_connection_id, p_buyer_id, p_seller_id, p_amount, v_currency,
        'awaiting_confirmation', false, false
    )
    RETURNING id INTO v_deal_id;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
        v_user_id, 'deal_created', 'deal', v_deal_id,
        jsonb_build_object('connection_id', p_connection_id,
                           'amount', p_amount, 'currency', v_currency)
    );
    RETURN v_deal_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_deal(p_deal_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_buyer_id uuid;
    v_seller_id uuid;
    v_buyer_confirmed boolean;
    v_seller_confirmed boolean;
    v_status text;
    v_new_buyer boolean;
    v_new_seller boolean;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

    SELECT d.buyer_id, d.seller_id, d.buyer_confirmed,
           d.seller_confirmed, d.status
    INTO v_buyer_id, v_seller_id, v_buyer_confirmed,
         v_seller_confirmed, v_status
    FROM public.deals d
    WHERE d.id = p_deal_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Deal not found'; END IF;
    IF v_user_id <> v_buyer_id AND v_user_id <> v_seller_id THEN
        RAISE EXCEPTION 'You are not a participant in this deal';
    END IF;
    IF v_status NOT IN ('in_progress', 'awaiting_confirmation') THEN
        RAISE EXCEPTION 'This deal cannot be confirmed in its current status';
    END IF;

    v_new_buyer := v_buyer_confirmed OR (v_user_id = v_buyer_id);
    v_new_seller := v_seller_confirmed OR (v_user_id = v_seller_id);

    UPDATE public.deals
    SET buyer_confirmed = v_new_buyer,
        seller_confirmed = v_new_seller,
        status = CASE WHEN v_new_buyer AND v_new_seller
                      THEN 'completed' ELSE 'awaiting_confirmation' END,
        completed_at = CASE
            WHEN v_new_buyer AND v_new_seller THEN COALESCE(completed_at, now())
            ELSE NULL
        END
    WHERE id = p_deal_id;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
        v_user_id, 'deal_confirmation_submitted', 'deal', p_deal_id,
        jsonb_build_object('buyer_confirmed', v_new_buyer,
                           'seller_confirmed', v_new_seller)
    );
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.report_deal_dispute(p_deal_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_user_id uuid := auth.uid();
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

    UPDATE public.deals
    SET status = 'disputed'
    WHERE id = p_deal_id
      AND (buyer_id = v_user_id OR seller_id = v_user_id)
      AND status IN ('in_progress', 'awaiting_confirmation');

    IF NOT FOUND THEN RAISE EXCEPTION 'Deal not found or cannot be disputed'; END IF;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'deal_disputed', 'deal', p_deal_id, '{}'::jsonb);
    RETURN true;
END;
$$;

-- 5. Reviews: only a participant in a completed deal can review the other party.
CREATE OR REPLACE FUNCTION public.submit_deal_review(
    p_deal_id uuid,
    p_rating integer,
    p_comment text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_buyer_id uuid;
    v_seller_id uuid;
    v_reviewee_id uuid;
    v_review_id uuid;
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
        RAISE EXCEPTION 'Rating must be between 1 and 5';
    END IF;

    SELECT d.buyer_id, d.seller_id
    INTO v_buyer_id, v_seller_id
    FROM public.deals d
    WHERE d.id = p_deal_id AND d.status = 'completed';

    IF NOT FOUND THEN RAISE EXCEPTION 'Only completed deals can be reviewed'; END IF;

    IF v_user_id = v_buyer_id THEN
        v_reviewee_id := v_seller_id;
    ELSIF v_user_id = v_seller_id THEN
        v_reviewee_id := v_buyer_id;
    ELSE
        RAISE EXCEPTION 'Only deal participants can submit a review';
    END IF;

    INSERT INTO public.reviews(deal_id, reviewer_id, reviewee_id, rating, comment)
    VALUES (p_deal_id, v_user_id, v_reviewee_id, p_rating, NULLIF(trim(p_comment), ''))
    RETURNING id INTO v_review_id;

    INSERT INTO public.notifications(
        recipient_id, actor_id, notification_type, title, message,
        entity_type, entity_id
    )
    VALUES (
        v_reviewee_id, v_user_id, 'new_review', 'You received a review',
        'A member left a review after a completed deal.', 'review', v_review_id
    );

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
        v_user_id, 'review_submitted', 'review', v_review_id,
        jsonb_build_object('deal_id', p_deal_id, 'rating', p_rating)
    );
    RETURN v_review_id;
END;
$$;

-- 6. Notification read function and connection/deal event notifications.
CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_user_id uuid := auth.uid();
BEGIN
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    UPDATE public.notifications
    SET is_read = true
    WHERE id = p_notification_id AND recipient_id = v_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Notification not found'; END IF;
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_connection_event()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.notifications(
            recipient_id, actor_id, notification_type, title, message,
            entity_type, entity_id
        )
        VALUES (
            NEW.offer_owner_id, NEW.requester_id, 'connection_request',
            'New connection request',
            'Someone has requested to connect with your listing.',
            'connection', NEW.id
        );
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NEW.status IN ('accepted', 'rejected') THEN
            INSERT INTO public.notifications(
                recipient_id, actor_id, notification_type, title, message,
                entity_type, entity_id
            )
            VALUES (
                NEW.requester_id, NEW.offer_owner_id,
                CASE WHEN NEW.status = 'accepted'
                     THEN 'connection_accepted' ELSE 'connection_rejected' END,
                CASE WHEN NEW.status = 'accepted'
                     THEN 'Connection accepted' ELSE 'Connection declined' END,
                CASE WHEN NEW.status = 'accepted'
                     THEN 'Your connection request was accepted.'
                     ELSE 'Your connection request was declined.' END,
                'connection', NEW.id
            );
        ELSIF NEW.status = 'cancelled' THEN
            INSERT INTO public.notifications(
                recipient_id, actor_id, notification_type, title, message,
                entity_type, entity_id
            )
            VALUES (
                NEW.offer_owner_id, NEW.requester_id, 'connection_cancelled',
                'Connection request cancelled',
                'A connection request was cancelled.',
                'connection', NEW.id
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS kwachalink_connection_notifications ON public.connections;
CREATE TRIGGER kwachalink_connection_notifications
AFTER INSERT OR UPDATE OF status ON public.connections
FOR EACH ROW EXECUTE FUNCTION public.notify_connection_event();

CREATE OR REPLACE FUNCTION public.notify_deal_event()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_actor uuid := auth.uid();
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.notifications(
            recipient_id, actor_id, notification_type, title, message,
            entity_type, entity_id
        )
        VALUES (
            CASE WHEN v_actor = NEW.buyer_id THEN NEW.seller_id ELSE NEW.buyer_id END,
            v_actor, 'deal_proposed', 'New deal proposal',
            'A deal has been proposed for your accepted connection.',
            'deal', NEW.id
        );
    ELSIF NEW.status = 'completed' AND OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO public.notifications(
            recipient_id, actor_id, notification_type, title, message,
            entity_type, entity_id
        )
        VALUES
        (NEW.buyer_id, v_actor, 'deal_completed', 'Deal completed',
         'Both participants confirmed this deal.', 'deal', NEW.id),
        (NEW.seller_id, v_actor, 'deal_completed', 'Deal completed',
         'Both participants confirmed this deal.', 'deal', NEW.id);
    ELSIF NEW.buyer_confirmed IS DISTINCT FROM OLD.buyer_confirmed
       OR NEW.seller_confirmed IS DISTINCT FROM OLD.seller_confirmed THEN
        INSERT INTO public.notifications(
            recipient_id, actor_id, notification_type, title, message,
            entity_type, entity_id
        )
        VALUES (
            CASE WHEN NEW.buyer_confirmed IS DISTINCT FROM OLD.buyer_confirmed
                 THEN NEW.seller_id ELSE NEW.buyer_id END,
            v_actor, 'deal_confirmation', 'Deal confirmation updated',
            'The other participant submitted a deal confirmation.',
            'deal', NEW.id
        );
    ELSIF NEW.status = 'disputed' AND OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO public.notifications(
            recipient_id, actor_id, notification_type, title, message,
            entity_type, entity_id
        )
        VALUES
        (NEW.buyer_id, v_actor, 'deal_disputed', 'Deal disputed',
         'A participant reported a dispute.', 'deal', NEW.id),
        (NEW.seller_id, v_actor, 'deal_disputed', 'Deal disputed',
         'A participant reported a dispute.', 'deal', NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS kwachalink_deal_notifications ON public.deals;
CREATE TRIGGER kwachalink_deal_notifications
AFTER INSERT OR UPDATE OF buyer_confirmed, seller_confirmed, status
ON public.deals
FOR EACH ROW EXECUTE FUNCTION public.notify_deal_event();

-- 7. Admin payment approval/rejection with manual review (no gateway/auto-payment).
CREATE OR REPLACE FUNCTION public.admin_approve_payment(
    p_payment_submission_id uuid,
    p_admin_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_payment public.payment_submissions%ROWTYPE;
    v_subscription_id uuid;
    v_admin_id uuid := auth.uid();
BEGIN
    IF v_admin_id IS NULL OR NOT public.is_kwachalink_admin() THEN
        RAISE EXCEPTION 'Administrator permission required';
    END IF;

    SELECT * INTO v_payment
    FROM public.payment_submissions
    WHERE id = p_payment_submission_id
    FOR UPDATE;

    IF NOT FOUND OR v_payment.status <> 'pending' THEN
        RAISE EXCEPTION 'Pending payment submission not found';
    END IF;

    IF v_payment.subscription_id IS NULL THEN
        INSERT INTO public.subscriptions(
            user_id, plan_name, amount_mwk, status, starts_at,
            expires_at, payment_reference
        )
        VALUES (
            v_payment.user_id, 'monthly', v_payment.amount_mwk, 'active',
            now(), now() + interval '1 month', v_payment.payment_reference
        )
        RETURNING id INTO v_subscription_id;
    ELSE
        UPDATE public.subscriptions
        SET status = 'active', starts_at = now(),
            expires_at = now() + interval '1 month',
            amount_mwk = v_payment.amount_mwk,
            payment_reference = v_payment.payment_reference
        WHERE id = v_payment.subscription_id
          AND user_id = v_payment.user_id
        RETURNING id INTO v_subscription_id;

        IF v_subscription_id IS NULL THEN
            RAISE EXCEPTION 'Linked subscription does not belong to this member';
        END IF;
    END IF;

    UPDATE public.payment_submissions
    SET status = 'approved', reviewed_at = now(),
        reviewed_by = v_admin_id, admin_notes = p_admin_notes
    WHERE id = p_payment_submission_id;

    INSERT INTO public.notifications(
        recipient_id, actor_id, notification_type, title, message,
        entity_type, entity_id
    )
    VALUES (
        v_payment.user_id, v_admin_id, 'payment_approved',
        'Payment approved',
        'Your membership payment was approved and your subscription is active.',
        'subscription', v_subscription_id
    );

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
        v_admin_id, 'payment_approved', 'payment_submission',
        p_payment_submission_id,
        jsonb_build_object('subscription_id', v_subscription_id,
                           'amount_mwk', v_payment.amount_mwk)
    );
    RETURN v_subscription_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reject_payment(
    p_payment_submission_id uuid,
    p_admin_notes text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_payment public.payment_submissions%ROWTYPE;
    v_admin_id uuid := auth.uid();
BEGIN
    IF v_admin_id IS NULL OR NOT public.is_kwachalink_admin() THEN
        RAISE EXCEPTION 'Administrator permission required';
    END IF;

    SELECT * INTO v_payment
    FROM public.payment_submissions
    WHERE id = p_payment_submission_id
    FOR UPDATE;

    IF NOT FOUND OR v_payment.status <> 'pending' THEN
        RAISE EXCEPTION 'Pending payment submission not found';
    END IF;

    UPDATE public.payment_submissions
    SET status = 'rejected', reviewed_at = now(),
        reviewed_by = v_admin_id, admin_notes = p_admin_notes
    WHERE id = p_payment_submission_id;

    INSERT INTO public.notifications(
        recipient_id, actor_id, notification_type, title, message,
        entity_type, entity_id
    )
    VALUES (
        v_payment.user_id, v_admin_id, 'payment_rejected',
        'Payment requires attention',
        COALESCE(NULLIF(trim(p_admin_notes), ''),
                 'Your payment submission was not approved. Please contact support.'),
        'payment_submission', p_payment_submission_id
    );

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
        v_admin_id, 'payment_rejected', 'payment_submission',
        p_payment_submission_id, jsonb_build_object('admin_notes', p_admin_notes)
    );
    RETURN true;
END;
$$;

-- 8. Admin/moderator management functions.
CREATE OR REPLACE FUNCTION public.admin_set_profile_verification(
    p_user_id uuid, p_status text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_admin_id uuid := auth.uid();
BEGIN
    IF v_admin_id IS NULL OR NOT public.is_kwachalink_admin() THEN
        RAISE EXCEPTION 'Administrator permission required';
    END IF;
    IF p_status NOT IN ('unverified', 'pending', 'verified', 'rejected') THEN
        RAISE EXCEPTION 'Invalid verification status';
    END IF;

    UPDATE public.profiles SET verification_status = p_status WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Member profile not found'; END IF;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
        v_admin_id, 'profile_verification_changed', 'profile', p_user_id,
        jsonb_build_object('verification_status', p_status)
    );
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_user_role(
    p_user_id uuid, p_role text, p_enabled boolean
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin_id uuid := auth.uid();
    v_admin_count integer;
BEGIN
    IF v_admin_id IS NULL OR NOT public.is_kwachalink_admin() THEN
        RAISE EXCEPTION 'Administrator permission required';
    END IF;
    IF p_role NOT IN ('user', 'moderator', 'admin') THEN
        RAISE EXCEPTION 'Invalid role';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'Member profile not found';
    END IF;

    IF p_enabled THEN
        INSERT INTO public.user_roles(user_id, role)
        VALUES (p_user_id, p_role)
        ON CONFLICT (user_id, role) DO NOTHING;
    ELSE
        IF p_role = 'admin' THEN
            SELECT count(*) INTO v_admin_count
            FROM public.user_roles WHERE role = 'admin';
            IF v_admin_count <= 1 THEN
                RAISE EXCEPTION 'The last administrator cannot be removed';
            END IF;
        END IF;
        DELETE FROM public.user_roles
        WHERE user_id = p_user_id AND role = p_role;
    END IF;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (
        v_admin_id, 'user_role_changed', 'profile', p_user_id,
        jsonb_build_object('role', p_role, 'enabled', p_enabled)
    );
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_offer_status(
    p_offer_id uuid, p_status text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_admin_id uuid := auth.uid();
BEGIN
    IF v_admin_id IS NULL OR NOT public.is_kwachalink_moderator() THEN
        RAISE EXCEPTION 'Moderator permission required';
    END IF;
    IF p_status NOT IN ('active', 'reserved', 'completed', 'cancelled') THEN
        RAISE EXCEPTION 'Invalid offer status';
    END IF;
    UPDATE public.offers SET status = p_status WHERE id = p_offer_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (v_admin_id, 'offer_status_changed', 'offer', p_offer_id,
            jsonb_build_object('status', p_status));
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_trade_listing_status(
    p_listing_id uuid, p_status text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_admin_id uuid := auth.uid();
BEGIN
    IF v_admin_id IS NULL OR NOT public.is_kwachalink_moderator() THEN
        RAISE EXCEPTION 'Moderator permission required';
    END IF;
    IF p_status NOT IN ('active', 'paused', 'completed', 'cancelled') THEN
        RAISE EXCEPTION 'Invalid trade listing status';
    END IF;
    UPDATE public.trade_listings
    SET status = p_status, updated_at = now()
    WHERE id = p_listing_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Trade listing not found'; END IF;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (v_admin_id, 'trade_listing_status_changed', 'trade_listing',
            p_listing_id, jsonb_build_object('status', p_status));
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_review_report(
    p_report_id uuid, p_status text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_admin_id uuid := auth.uid();
BEGIN
    IF v_admin_id IS NULL OR NOT public.is_kwachalink_moderator() THEN
        RAISE EXCEPTION 'Moderator permission required';
    END IF;
    IF p_status NOT IN ('investigating', 'resolved', 'dismissed') THEN
        RAISE EXCEPTION 'Invalid report status';
    END IF;
    UPDATE public.reports
    SET status = p_status,
        resolved_at = CASE
            WHEN p_status IN ('resolved', 'dismissed') THEN now()
            ELSE NULL
        END
    WHERE id = p_report_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Report not found'; END IF;

    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES (v_admin_id, 'report_status_changed', 'report', p_report_id,
            jsonb_build_object('status', p_status));
    RETURN true;
END;
$$;

-- 9. Remove direct writes to sensitive workflow tables; RPCs handle changes.
REVOKE INSERT, UPDATE, DELETE ON public.deals FROM anon, authenticated;
GRANT SELECT ON public.deals TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON public.reviews FROM anon, authenticated;
GRANT SELECT ON public.reviews TO authenticated;

REVOKE UPDATE, DELETE ON public.payment_submissions FROM anon, authenticated;
GRANT SELECT, INSERT ON public.payment_submissions TO authenticated;

REVOKE UPDATE, DELETE ON public.notifications FROM anon, authenticated;
GRANT SELECT ON public.notifications TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON public.subscriptions FROM anon, authenticated;
GRANT SELECT ON public.subscriptions TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON public.user_roles FROM anon, authenticated;
GRANT SELECT ON public.user_roles TO authenticated;

REVOKE UPDATE, DELETE ON public.reports FROM anon, authenticated;
GRANT SELECT, INSERT ON public.reports TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON public.audit_logs FROM anon, authenticated;
GRANT SELECT ON public.audit_logs TO authenticated;

GRANT SELECT, INSERT ON public.connections TO authenticated;
GRANT SELECT, INSERT ON public.messages TO authenticated;

-- 10. Admin/moderator read policies.
DROP POLICY IF EXISTS "Admins view all payment submissions" ON public.payment_submissions;
CREATE POLICY "Admins view all payment submissions"
ON public.payment_submissions FOR SELECT TO authenticated
USING (public.is_kwachalink_admin());

DROP POLICY IF EXISTS "Admins view all subscriptions" ON public.subscriptions;
CREATE POLICY "Admins view all subscriptions"
ON public.subscriptions FOR SELECT TO authenticated
USING (public.is_kwachalink_admin());

DROP POLICY IF EXISTS "Admins view all user roles" ON public.user_roles;
CREATE POLICY "Admins view all user roles"
ON public.user_roles FOR SELECT TO authenticated
USING (public.is_kwachalink_admin());

DROP POLICY IF EXISTS "Admins view all reports" ON public.reports;
CREATE POLICY "Admins view all reports"
ON public.reports FOR SELECT TO authenticated
USING (public.is_kwachalink_moderator());

DROP POLICY IF EXISTS "Admins view audit logs" ON public.audit_logs;
CREATE POLICY "Admins view audit logs"
ON public.audit_logs FOR SELECT TO authenticated
USING (public.is_kwachalink_admin());

DROP POLICY IF EXISTS "Admins view member profiles" ON public.profiles;
CREATE POLICY "Admins view member profiles"
ON public.profiles FOR SELECT TO authenticated
USING (public.is_kwachalink_admin());

DROP POLICY IF EXISTS "Users update own notifications" ON public.notifications;

-- 11. RPC permissions.
REVOKE ALL ON FUNCTION public.create_deal(uuid, uuid, uuid, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_deal(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_deal_dispute(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_deal_review(uuid, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_notification_read(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_approve_payment(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_reject_payment(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_profile_verification(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_user_role(uuid, text, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_offer_status(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_trade_listing_status(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_review_report(uuid, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_deal(uuid, uuid, uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_deal(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_deal_dispute(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_deal_review(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_approve_payment(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reject_payment(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_profile_verification(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_role(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_offer_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_trade_listing_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_review_report(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.notify_connection_event() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notify_deal_event() FROM PUBLIC, anon, authenticated;

-- 12. Bootstrap the first administrator account.
DO $$
DECLARE
    v_admin_email text := 'msukwainno@gmail.com';
    v_admin_id uuid;
BEGIN
    SELECT id INTO v_admin_id
    FROM auth.users
    WHERE lower(email) = lower(v_admin_email);

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No Supabase Auth account found for %. Create/sign in to this account first.',
            v_admin_email;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_admin_id) THEN
        RAISE EXCEPTION
            'The Auth account exists but has no public.profiles row. Complete its profile first.';
    END IF;

    INSERT INTO public.user_roles(user_id, role)
    VALUES (v_admin_id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
END;
$$;

COMMIT;

/*
IMPORTANT IMPLEMENTATION NOTES FOR BOLT:
- Deal creation: supabase.rpc('create_deal', {p_connection_id, p_buyer_id, p_seller_id, p_amount, p_currency})
- Confirmation: supabase.rpc('confirm_deal', {p_deal_id})
- Dispute: supabase.rpc('report_deal_dispute', {p_deal_id})
- Review: supabase.rpc('submit_deal_review', {p_deal_id, p_rating, p_comment})
- Mark notification read: supabase.rpc('mark_notification_read', {p_notification_id})
- Admin payment approval: supabase.rpc('admin_approve_payment', {p_payment_submission_id, p_admin_notes})
- Admin payment rejection: supabase.rpc('admin_reject_payment', {p_payment_submission_id, p_admin_notes})
- Profile verification: supabase.rpc('admin_set_profile_verification', {p_user_id, p_status})
- Role changes: supabase.rpc('admin_set_user_role', {p_user_id, p_role, p_enabled})
- Moderation: admin_set_offer_status, admin_set_trade_listing_status, admin_review_report.
- No payment gateway or escrow is created. Membership payments remain manually reviewed.
- A deal record/confirmation is a user-reported record, not proof of payment or settlement.
- Forex functions must not be marketed as an authorised exchange service absent regulatory review.
- Test ordinary-member and admin flows before production launch.
*/
