export interface IPortalMoveStudentsConfig {
  new_class_info_url: string; // there isn't an old_class_info_url because we don't need to match against the old class url
  old_context_id: string; // this should be the old class's class_hash value in the portal
  new_context_id: string; // this should be the new class's class_hash value in the portal
  platform_id: string; // the portal URL including protocol
  platform_user_id: string; // the portal user ID
  assignments: IPortalMoveStudentsAssignment[];
}

export interface IPortalMoveStudentsAssignment {
  old_resource_link_id: string; // this is the offering_id in the portal
  new_resource_link_id: string; // this is the offering_id in the portal
  tool_id: string; // this should be the hostname of the LARA instance
}
