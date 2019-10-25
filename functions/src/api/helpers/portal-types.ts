export interface IPortalMoveStudentsConfig {
  class_info_url: string;
  old_context_id: string;
  new_context_id: string;
  platform_id: string;
  platform_user_id: string;
  assignments: IPortalMoveStudentsAssignment[];
}

export interface IPortalMoveStudentsAssignment {
  // change the first two to strings in the portal
  old_resource_link_id: string;
  new_resource_link_id: string;
  tool_id: string;
}
